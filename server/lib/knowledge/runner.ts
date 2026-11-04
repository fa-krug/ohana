// The worker's KnowledgeRunner: turns pending documents (text the app uploaded, waiting) into
// chunks for the search, like the meals' ImportRunner runs recipe imports. The cards come after,
// from the KnowledgeCardRunner (card-runner.ts).
//
// Claiming is a compare-and-swap UPDATE … RETURNING (still pending, the lease as the tick read
// it) that takes a lease with a fresh run token (`run_token`, `run_until`) and reads the text in
// the same statement, so no document runs twice and the run has exactly the text it claimed. An
// upload of new text, a reindex, excluding a document and marking it missing all clear the lease,
// so every write of a run (ready with its chunks, or failed) happens in one immediate transaction
// that first checks the run token is still the document's: a run that lost it writes nothing, and
// the newer state stays. A worker that died leaves a pending document whose lease runs out: it is
// run once more, then marked failed.
//
// A document whose text is empty (no pages, or only empty ones: a scan without OCR, a format the
// device read nothing from) becomes ready without chunks; the app shows it has no text.

import { and, asc, eq, inArray, isNull, lte, or } from "drizzle-orm";
import { HttpError, randomToken } from "@/lib/api/http";
import type { Db } from "@/lib/db";
import { kbChunks, kbDocuments } from "@/lib/db/schema";
import { moduleEnabled } from "@/lib/server-info";
import { type TextChunk, chunkPages, storedPages } from "./chunk";
import { CARD_RESET, deleteChunks } from "./documents";

/** How long one document's chunks may take. */
export const KNOWLEDGE_TIMEOUT_MS = 4 * 60_000;
/** The lease a running document holds (longer than it may take). */
export const KNOWLEDGE_LEASE_MS = 6 * 60_000;
/** Runs of one text before a lost one counts as failed. */
export const MAX_KNOWLEDGE_ATTEMPTS = 2;
/** Chunks per INSERT (SQLite's limit on bound variables). */
const INSERT_BATCH = 200;
/** The longest error a document keeps. */
const MAX_ERROR = 300;

/** What a tick reads of a due document (not its text: that comes with the claim). */
type Due = Pick<typeof kbDocuments.$inferSelect, "id" | "familyId" | "runToken" | "runUntil" | "attempts">;

export interface KnowledgeRunnerOptions {
  maxConcurrent?: number;
  /** Replaces chunkPages (tests: a failing or a slow one). */
  chunker?: (pages: string[]) => TextChunk[] | Promise<TextChunk[]>;
  now?: () => Date;
  timeoutMs?: number;
  leaseMs?: number;
  log?: (msg: string) => void;
}

interface Running {
  abort: AbortController;
  token: string;
}

/** The document as the tick read it still holds: pending, same lease. */
function held(d: Due) {
  return and(
    eq(kbDocuments.id, d.id),
    eq(kbDocuments.status, "pending"),
    d.runToken === null ? isNull(kbDocuments.runToken) : eq(kbDocuments.runToken, d.runToken),
  );
}

function shortError(err: unknown): string {
  const message = err instanceof HttpError ? err.message : err instanceof Error && err.message ? err.message : "Indexing failed";
  return message.length > MAX_ERROR ? `${message.slice(0, MAX_ERROR - 1)}…` : message;
}

/** The worker's knowledge loop: every tick one cheap indexed query finds the pending documents
 *  whose lease is free (or ran out), claims each and runs it WITHOUT awaiting, at most
 *  `maxConcurrent` at once. */
export class KnowledgeRunner {
  private readonly running = new Map<string, Running>();
  private readonly done = new Map<string, Promise<void>>();
  private stopped = false;
  private readonly maxConcurrent: number;
  private readonly chunker: (pages: string[]) => TextChunk[] | Promise<TextChunk[]>;
  private readonly now: () => Date;
  private readonly timeoutMs: number;
  private readonly leaseMs: number;
  private readonly log: (msg: string) => void;

  constructor(
    private readonly db: Db,
    opts: KnowledgeRunnerOptions = {},
  ) {
    this.maxConcurrent = opts.maxConcurrent ?? Math.max(1, Number(process.env.KNOWLEDGE_MAX_CONCURRENT) || 2);
    this.chunker = opts.chunker ?? chunkPages;
    this.now = opts.now ?? (() => new Date());
    this.timeoutMs = opts.timeoutMs ?? KNOWLEDGE_TIMEOUT_MS;
    this.leaseMs = opts.leaseMs ?? KNOWLEDGE_LEASE_MS;
    this.log = opts.log ?? ((m) => console.log(`[knowledge] ${m}`));
  }

  get active(): number {
    return this.running.size;
  }

  /** Aborts the runs whose lease is gone, gives up on lost ones that ran too often, then claims
   *  and starts pending ones; returns how many were started. Never throws. */
  tick(now = this.now()): number {
    if (this.stopped || !moduleEnabled("knowledge")) return 0;
    let started = 0;
    try {
      if (this.running.size) {
        const rows = this.db
          .select({ id: kbDocuments.id, runToken: kbDocuments.runToken })
          .from(kbDocuments)
          .where(inArray(kbDocuments.id, [...this.running.keys()]))
          .all();
        const tokens = new Map(rows.map((r) => [r.id, r.runToken]));
        for (const [id, run] of this.running) {
          if (tokens.get(id) !== run.token) run.abort.abort("lost");
        }
      }
      const free = this.maxConcurrent - this.running.size;
      if (free <= 0) return 0;
      const due = this.db
        .select({
          id: kbDocuments.id,
          familyId: kbDocuments.familyId,
          runToken: kbDocuments.runToken,
          runUntil: kbDocuments.runUntil,
          attempts: kbDocuments.attempts,
        })
        .from(kbDocuments)
        .where(
          and(
            eq(kbDocuments.status, "pending"),
            or(isNull(kbDocuments.runUntil), lte(kbDocuments.runUntil, now)),
          ),
        )
        .orderBy(asc(kbDocuments.updatedAt), asc(kbDocuments.id))
        .limit(free)
        .all();
      for (const doc of due) {
        if (this.running.has(doc.id)) continue;
        if (doc.runToken !== null && doc.attempts >= MAX_KNOWLEDGE_ATTEMPTS) {
          this.interrupted(doc, now);
          continue;
        }
        if (this.running.size >= this.maxConcurrent) break;
        if (this.start(doc, now)) started += 1;
      }
    } catch (err) {
      console.error("[knowledge] tick failed:", err);
    }
    return started;
  }

  private start(doc: Due, now: Date): boolean {
    const token = randomToken(32);
    const claimed = this.db
      .update(kbDocuments)
      .set({ runToken: token, runUntil: new Date(now.getTime() + this.leaseMs), attempts: doc.attempts + 1 })
      .where(held(doc))
      .returning({ text: kbDocuments.text })
      .get();
    if (!claimed) return false;
    if (doc.runToken !== null) this.log(`indexing document ${doc.id} again (its worker went away)`);
    const run: Running = { abort: new AbortController(), token };
    this.running.set(doc.id, run);
    const p = this.run(doc, claimed.text, run)
      .catch((err) => console.error(`[knowledge] document ${doc.id} failed:`, err))
      .finally(() => {
        this.running.delete(doc.id);
        this.done.delete(doc.id);
        // More may wait: the next one starts without waiting for the tick.
        this.tick();
      });
    this.done.set(doc.id, p);
    return true;
  }

  private async run(doc: Due, text: string, run: Running): Promise<void> {
    const timeout = AbortSignal.timeout(this.timeoutMs);
    const signal = AbortSignal.any([run.abort.signal, timeout]);
    // A turn of the event loop first: a long queue doesn't hold the worker in one go.
    await new Promise((resolve) => setImmediate(resolve));
    let chunks: TextChunk[];
    try {
      signal.throwIfAborted();
      chunks = await this.chunker(storedPages(text));
      signal.throwIfAborted();
    } catch (err) {
      if (run.abort.signal.aborted) {
        // Lost its lease (new text, excluded, missing): the newer state stays. Stopping: the
        // next worker takes it over.
        if (this.stopped) this.release(doc, run);
        return;
      }
      const message = timeout.aborted ? "Indexing took too long" : shortError(err);
      if (!(err instanceof HttpError) && !timeout.aborted) console.error(`[knowledge] document ${doc.id} failed:`, err);
      this.fail(doc, run, message);
      return;
    }
    if (!this.finish(doc, run, chunks)) {
      this.log(`document ${doc.id} changed while it was indexed, its result is dropped`);
      return;
    }
    // The card comes after, from the KnowledgeCardRunner (card-runner.ts): the document is
    // searchable without one.
  }

  /** The chunks in, the document ready, its card to be made again (new chunks, new ids for the
   *  facts' sources; none without text); false (nothing written) when the run lost its lease. */
  private finish(doc: Due, run: Running, chunks: TextChunk[]): boolean {
    const now = this.now();
    return this.db.transaction(
      (tx) => {
        if (!this.stillMine(tx, doc, run)) return false;
        deleteChunks(tx, doc.id);
        for (let i = 0; i < chunks.length; i += INSERT_BATCH) {
          const values = chunks.slice(i, i + INSERT_BATCH).map((c) => ({
            documentId: doc.id,
            familyId: doc.familyId,
            seq: c.seq,
            page: c.page,
            text: c.text,
          }));
          tx.insert(kbChunks).values(values).run();
        }
        tx.update(kbDocuments)
          .set({
            status: "ready",
            indexedAt: now,
            error: null,
            runToken: null,
            runUntil: null,
            ...CARD_RESET,
            cardStatus: chunks.length ? "pending" : "none",
            updatedAt: now,
          })
          .where(eq(kbDocuments.id, doc.id))
          .run();
        return true;
      },
      { behavior: "immediate" },
    );
  }

  /** Failed with `error` (its chunks go: a failed document isn't searchable); nothing written
   *  when the run lost its lease. */
  private fail(doc: Due, run: Running, error: string): void {
    const now = this.now();
    this.db.transaction(
      (tx) => {
        if (!this.stillMine(tx, doc, run)) return;
        deleteChunks(tx, doc.id);
        tx.update(kbDocuments)
          .set({ status: "failed", error, indexedAt: null, runToken: null, runUntil: null, updatedAt: now })
          .where(eq(kbDocuments.id, doc.id))
          .run();
      },
      { behavior: "immediate" },
    );
  }

  private stillMine(tx: Pick<Db, "select">, doc: Due, run: Running): boolean {
    const row = tx
      .select({ status: kbDocuments.status, runToken: kbDocuments.runToken })
      .from(kbDocuments)
      .where(eq(kbDocuments.id, doc.id))
      .get();
    return row?.status === "pending" && row.runToken === run.token;
  }

  /** Back to waiting, as if this worker had never claimed it. */
  private release(doc: Due, run: Running): void {
    this.db
      .update(kbDocuments)
      .set({ runToken: null, runUntil: null, attempts: doc.attempts })
      .where(and(eq(kbDocuments.id, doc.id), eq(kbDocuments.runToken, run.token)))
      .run();
  }

  /** A lost run that ran too often: failed (without chunks, as `fail`). */
  private interrupted(doc: Due, now: Date): void {
    const failed = this.db.transaction(
      (tx) => {
        const changed =
          tx
            .update(kbDocuments)
            .set({ status: "failed", error: "Indexing was interrupted", indexedAt: null, runToken: null, runUntil: null, updatedAt: now })
            .where(held(doc))
            .run().changes === 1;
        if (changed) deleteChunks(tx, doc.id);
        return changed;
      },
      { behavior: "immediate" },
    );
    if (failed) this.log(`document ${doc.id} was interrupted ${doc.attempts} times, marked failed`);
  }

  /** Waits for the running documents until all ended or `ms` passed. */
  async idle(ms = Infinity): Promise<void> {
    const until = Date.now() + ms;
    while (this.done.size && Date.now() < until) {
      await Promise.race([
        Promise.allSettled([...this.done.values()]),
        new Promise((r) => setTimeout(r, Math.min(50, until - Date.now()))),
      ]);
    }
  }

  /** Stops: the runs end where they are and their documents wait again for the next worker. */
  async stop(ms: number): Promise<void> {
    this.stopped = true;
    for (const run of this.running.values()) run.abort.abort("stop");
    await this.idle(ms);
  }
}
