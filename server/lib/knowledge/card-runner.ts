// The worker's KnowledgeCardRunner: makes the card (card.ts) of every ready document whose card
// is pending, after the KnowledgeRunner chunked it. Only for families whose AI is set up (and
// with the assistant on): the others' documents wait, pending, until it is. The document stays
// searchable whatever happens to its card.
//
// The same pattern as the KnowledgeRunner: a compare-and-swap UPDATE claims the card with a fresh
// run token (`card_run_token`, `card_run_until`, `card_attempts`); whatever changes the chunks
// (new text, a reindex, letting it back in, a new run of the chunker) or the status (excluded,
// missing) clears that lease, so the card's write, one immediate transaction, first checks the
// document is still ready with the same hash and `indexed_at` and the token is still its own: a
// stale card is never written. A failure marks the card failed with a short reason; a temporary
// one (the AI busy, down or unreachable, a timeout: TemporaryCardError) lets it wait instead,
// longer each time (CARD_BACKOFF_MS: `card_run_until` without a token is "not before"), and
// fails it the MAX_CARD_RETRIES-th time. A worker that died leaves a lease that runs out: run
// once more, then failed.
//
// A document with page scans still waiting or running (scan-runner.ts) waits too: its text is about
// to change, and the transcription resets the card anyway.
//
// Fair between families: at most one card per family at a time, and a free slot goes to the
// family whose oldest waiting document is the oldest (so one family's thousand documents don't
// hold up another's few). New cards come before rewrites (a card waiting while it still shows its
// earlier summary, POST /knowledge/cards): a family with a new document waiting goes first, and in
// a family its new documents do.

import { and, asc, eq, inArray, isNull, lte, ne, notInArray, or, sql } from "drizzle-orm";
import { HttpError, randomToken } from "@/lib/api/http";
import { type AiEnv, familyModel } from "@/lib/assistant/routes";
import type { Db } from "@/lib/db";
import { aiSettings, kbChunks, kbDocuments, kbPageScans } from "@/lib/db/schema";
import { familyNames } from "@/lib/families/people";
import { familyLocale } from "@/lib/notifications/locale";
import { moduleEnabled } from "@/lib/server-info";
import { CARD_TIMEOUT_MS, type Card, type CardInput, TemporaryCardError, makeCard } from "./card";
import { parseJsonArray } from "./documents";

/** The lease a running card holds (longer than it may take). */
export const CARD_LEASE_MS = 5 * 60_000;
/** Runs of one card before a lost one counts as failed. */
export const MAX_CARD_ATTEMPTS = 2;
/** How long a card waits after its 1st, 2nd, … temporary failure; the MAX_CARD_RETRIES-th fails it. */
export const CARD_BACKOFF_MS = [5 * 60_000, 30 * 60_000, 2 * 60 * 60_000, 2 * 60 * 60_000];
export const MAX_CARD_RETRIES = 5;
/** The longest error a card keeps. */
const MAX_ERROR = 200;

type Due = Pick<
  typeof kbDocuments.$inferSelect,
  "id" | "familyId" | "cardRunToken" | "cardRunUntil" | "cardAttempts" | "cardRetries"
>;

/** What the claim reads: the document as the card is made of it. */
interface Claimed {
  name: string;
  path: string;
  tags: string;
  hash: string;
  indexedAt: Date | null;
}

export interface KnowledgeCardRunnerOptions {
  maxConcurrent?: number;
  /** Replaces makeCard (tests). */
  maker?: (env: AiEnv, familyId: string, input: CardInput, signal: AbortSignal) => Promise<Card | null>;
  now?: () => Date;
  timeoutMs?: number;
  leaseMs?: number;
  log?: (msg: string) => void;
}

interface Running {
  abort: AbortController;
  token: string;
  familyId: string;
}

/** The family's model makes the card; null when the family's AI isn't set up (any more). */
async function defaultMaker(env: AiEnv, familyId: string, input: CardInput, signal: AbortSignal): Promise<Card | null> {
  const model = await familyModel(env, familyId);
  if (!model) return null;
  return makeCard(model.provider, input, env.modelNet, signal);
}

/** The card as the tick read it still waits: ready, pending, same lease. */
function held(d: Due) {
  return and(
    eq(kbDocuments.id, d.id),
    eq(kbDocuments.status, "ready"),
    eq(kbDocuments.cardStatus, "pending"),
    d.cardRunToken === null ? isNull(kbDocuments.cardRunToken) : eq(kbDocuments.cardRunToken, d.cardRunToken),
  );
}

function shortError(err: unknown): string {
  const message = err instanceof HttpError ? err.message : "Making the card failed";
  return message.length > MAX_ERROR ? `${message.slice(0, MAX_ERROR - 1)}…` : message;
}

export class KnowledgeCardRunner {
  private readonly running = new Map<string, Running>();
  private readonly done = new Map<string, Promise<void>>();
  private stopped = false;
  private readonly db: Db;
  private readonly maxConcurrent: number;
  private readonly maker: NonNullable<KnowledgeCardRunnerOptions["maker"]>;
  private readonly now: () => Date;
  private readonly timeoutMs: number;
  private readonly leaseMs: number;
  private readonly log: (msg: string) => void;

  constructor(
    private readonly env: AiEnv,
    opts: KnowledgeCardRunnerOptions = {},
  ) {
    this.db = env.db;
    this.maxConcurrent = opts.maxConcurrent ?? Math.max(1, Number(process.env.KNOWLEDGE_CARD_CONCURRENT) || 1);
    this.maker = opts.maker ?? defaultMaker;
    this.now = opts.now ?? (() => new Date());
    this.timeoutMs = opts.timeoutMs ?? CARD_TIMEOUT_MS + 30_000;
    this.leaseMs = opts.leaseMs ?? CARD_LEASE_MS;
    this.log = opts.log ?? ((m) => console.log(`[knowledge] ${m}`));
  }

  get active(): number {
    return this.running.size;
  }

  /** Aborts the runs whose lease is gone, gives up on lost ones that ran too often, then claims
   *  and starts waiting cards of families with their AI set up; returns how many were started.
   *  Never throws. */
  tick(now = this.now()): number {
    if (this.stopped || !moduleEnabled("knowledge") || !moduleEnabled("assistant")) return 0;
    let started = 0;
    try {
      if (this.running.size) {
        const rows = this.db
          .select({ id: kbDocuments.id, token: kbDocuments.cardRunToken })
          .from(kbDocuments)
          .where(inArray(kbDocuments.id, [...this.running.keys()]))
          .all();
        const tokens = new Map(rows.map((r) => [r.id, r.token]));
        for (const [id, run] of this.running) {
          if (tokens.get(id) !== run.token) run.abort.abort("lost");
        }
      }
      const free = this.maxConcurrent - this.running.size;
      if (free <= 0) return 0;
      const waiting = and(
        eq(kbDocuments.cardStatus, "pending"),
        eq(kbDocuments.status, "ready"),
        or(isNull(kbDocuments.cardRunUntil), lte(kbDocuments.cardRunUntil, now)),
        // Not while page scans of it wait to be read: its text is about to change.
        sql`not exists (select 1 from ${kbPageScans} where ${kbPageScans.documentId} = ${kbDocuments.id} and ${kbPageScans.status} in ('waiting', 'running'))`,
      );
      // The families with a card due and none running, the longest waiting first.
      const busy = [...new Set([...this.running.values()].map((r) => r.familyId))];
      const oldest = sql`min(${kbDocuments.indexedAt})`;
      const rewrite = sql`(${kbDocuments.summary} is not null)`;
      const families = this.db
        .select({ familyId: kbDocuments.familyId })
        .from(kbDocuments)
        .innerJoin(aiSettings, eq(aiSettings.familyId, kbDocuments.familyId))
        .where(
          and(
            waiting,
            ne(aiSettings.baseUrl, ""),
            ne(aiSettings.model, ""),
            busy.length ? notInArray(kbDocuments.familyId, busy) : undefined,
          ),
        )
        .groupBy(kbDocuments.familyId)
        .orderBy(sql`min${rewrite}`, oldest, kbDocuments.familyId)
        .limit(free)
        .all();
      for (const { familyId } of families) {
        if (this.running.size >= this.maxConcurrent) break;
        const doc = this.db
          .select({
            id: kbDocuments.id,
            familyId: kbDocuments.familyId,
            cardRunToken: kbDocuments.cardRunToken,
            cardRunUntil: kbDocuments.cardRunUntil,
            cardAttempts: kbDocuments.cardAttempts,
            cardRetries: kbDocuments.cardRetries,
          })
          .from(kbDocuments)
          .where(and(eq(kbDocuments.familyId, familyId), waiting))
          .orderBy(rewrite, asc(kbDocuments.indexedAt), asc(kbDocuments.id))
          .limit(1)
          .get();
        if (!doc || this.running.has(doc.id)) continue;
        if (doc.cardRunToken !== null && doc.cardAttempts >= MAX_CARD_ATTEMPTS) {
          // The family's next one gets its turn with the next tick.
          this.interrupted(doc);
          continue;
        }
        if (this.start(doc, now)) started += 1;
      }
    } catch (err) {
      console.error("[knowledge] card tick failed:", err);
    }
    return started;
  }

  private start(doc: Due, now: Date): boolean {
    const token = randomToken(32);
    const claimed = this.db
      .update(kbDocuments)
      .set({ cardRunToken: token, cardRunUntil: new Date(now.getTime() + this.leaseMs), cardAttempts: doc.cardAttempts + 1 })
      .where(held(doc))
      .returning({ name: kbDocuments.name, path: kbDocuments.path, tags: kbDocuments.tags, hash: kbDocuments.hash, indexedAt: kbDocuments.indexedAt })
      .get();
    if (!claimed) return false;
    if (doc.cardRunToken !== null) this.log(`making the card of document ${doc.id} again (its worker went away)`);
    const run: Running = { abort: new AbortController(), token, familyId: doc.familyId };
    this.running.set(doc.id, run);
    const p = this.run(doc, claimed, run)
      .catch((err) => console.error(`[knowledge] card of document ${doc.id} failed:`, err))
      .finally(() => {
        this.running.delete(doc.id);
        this.done.delete(doc.id);
        this.tick();
      });
    this.done.set(doc.id, p);
    return true;
  }

  private async run(doc: Due, claimed: Claimed, run: Running): Promise<void> {
    const timeout = AbortSignal.timeout(this.timeoutMs);
    const signal = AbortSignal.any([run.abort.signal, timeout]);
    await new Promise((resolve) => setImmediate(resolve));
    const chunks = this.db
      .select({ id: kbChunks.id, seq: kbChunks.seq, page: kbChunks.page, text: kbChunks.text })
      .from(kbChunks)
      .where(eq(kbChunks.documentId, doc.id))
      .orderBy(asc(kbChunks.seq))
      .all();
    if (!chunks.length) {
      // Nothing to make a card of (a document ready without text).
      this.write(doc, claimed, run, { cardStatus: "none" });
      return;
    }
    let card: Card | null;
    try {
      signal.throwIfAborted();
      const people = familyNames(this.db, doc.familyId).map(({ id, name, account }) => ({ id, name, account }));
      const input: CardInput = {
        lang: familyLocale(this.db, doc.familyId),
        people,
        name: claimed.name,
        path: claimed.path,
        tags: parseJsonArray<string>(claimed.tags) ?? [],
        chunks,
      };
      card = await this.maker(this.env, doc.familyId, input, signal);
      signal.throwIfAborted();
    } catch (err) {
      if (run.abort.signal.aborted) {
        // Lost its lease (the chunks or the status changed): the newer state stays. Stopping:
        // the next worker takes it over.
        if (this.stopped) this.release(doc, run);
        return;
      }
      const message = timeout.aborted ? "Making the card took too long" : shortError(err);
      if (!(err instanceof HttpError) && !timeout.aborted) console.error(`[knowledge] card of document ${doc.id} failed:`, err);
      if (timeout.aborted || err instanceof TemporaryCardError) this.retryLater(doc, claimed, run, message);
      else this.write(doc, claimed, run, { cardStatus: "failed", cardError: message });
      return;
    }
    if (!card) {
      // The family's AI went away meanwhile: back to waiting for it.
      this.release(doc, run);
      return;
    }
    if (card.dropped) this.log(`card of document ${doc.id}: ${card.dropped} fact(s) dropped, their quote isn't in the text`);
    const written = this.write(doc, claimed, run, {
      cardStatus: "ready",
      summary: card.summary,
      facts: JSON.stringify(card.facts),
      keywords: JSON.stringify(card.keywords),
      docDate: card.docDate,
      personUserId: card.person?.account ? card.person.id : null,
      personPersonId: card.person && !card.person.account ? card.person.id : null,
    });
    if (!written) this.log(`document ${doc.id} changed while its card was made, the card is dropped`);
  }

  /** A temporary failure: the card waits CARD_BACKOFF_MS (this claim not counted as a run), or
   *  fails after MAX_CARD_RETRIES of them. */
  private retryLater(doc: Due, claimed: Claimed, run: Running, message: string): void {
    const retries = doc.cardRetries + 1;
    if (retries >= MAX_CARD_RETRIES) {
      this.write(doc, claimed, run, { cardStatus: "failed", cardError: message, cardRetries: retries });
      return;
    }
    const wait = CARD_BACKOFF_MS[Math.min(retries, CARD_BACKOFF_MS.length) - 1];
    const written = this.write(doc, claimed, run, {
      cardError: message,
      cardRetries: retries,
      cardAttempts: doc.cardAttempts,
      cardRunUntil: new Date(this.now().getTime() + wait),
    });
    if (written) this.log(`card of document ${doc.id} failed for now (${message}), tried again in ${Math.round(wait / 60_000)} min`);
  }

  /** Writes the card's outcome (and frees the lease) only while the document is still ready with
   *  the text the card was made of and the lease is this run's. */
  private write(doc: Due, claimed: Claimed, run: Running, set: Partial<typeof kbDocuments.$inferInsert>): boolean {
    return this.db.transaction(
      (tx) => {
        const row = tx
          .select({
            status: kbDocuments.status,
            cardStatus: kbDocuments.cardStatus,
            hash: kbDocuments.hash,
            indexedAt: kbDocuments.indexedAt,
            token: kbDocuments.cardRunToken,
          })
          .from(kbDocuments)
          .where(eq(kbDocuments.id, doc.id))
          .get();
        const same =
          row?.status === "ready" &&
          row.cardStatus === "pending" &&
          row.token === run.token &&
          row.hash === claimed.hash &&
          row.indexedAt?.getTime() === claimed.indexedAt?.getTime();
        if (!same) return false;
        tx.update(kbDocuments)
          .set({ cardError: null, cardRunUntil: null, ...set, cardRunToken: null })
          .where(eq(kbDocuments.id, doc.id))
          .run();
        return true;
      },
      { behavior: "immediate" },
    );
  }

  /** Back to waiting, as if this worker had never claimed it. */
  private release(doc: Due, run: Running): void {
    this.db
      .update(kbDocuments)
      .set({ cardRunToken: null, cardRunUntil: null, cardAttempts: doc.cardAttempts })
      .where(and(eq(kbDocuments.id, doc.id), eq(kbDocuments.cardRunToken, run.token)))
      .run();
  }

  /** A lost run that ran too often: the card failed. */
  private interrupted(doc: Due): void {
    const changed = this.db
      .update(kbDocuments)
      .set({ cardStatus: "failed", cardError: "Making the card was interrupted", cardRunToken: null, cardRunUntil: null })
      .where(held(doc))
      .run().changes;
    if (changed) this.log(`card of document ${doc.id} was interrupted ${doc.cardAttempts} times, marked failed`);
  }

  /** Waits for the running cards until all ended or `ms` passed. */
  async idle(ms = Infinity): Promise<void> {
    const until = Date.now() + ms;
    while (this.done.size && Date.now() < until) {
      await Promise.race([
        Promise.allSettled([...this.done.values()]),
        new Promise((r) => setTimeout(r, Math.min(50, until - Date.now()))),
      ]);
    }
  }

  /** Stops: the runs end where they are and their cards wait again for the next worker. */
  async stop(ms: number): Promise<void> {
    this.stopped = true;
    for (const run of this.running.values()) run.abort.abort("stop");
    await this.idle(ms);
  }
}
