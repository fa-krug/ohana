// The worker's KnowledgeScanRunner: has the family's AI transcribe the page scans the app sent
// (scans.ts) and puts the transcription in place of the page's text. Only for families whose AI
// is set up (and with the assistant on); a scan the app sent on its own (not forced) only while
// the family has `ai_scans` on. The document then goes back to pending with its card reset, so it
// is chunked and summarised anew; the card runner waits meanwhile for documents with scans still
// waiting or running (no card of text about to change).
//
// The same pattern as the KnowledgeCardRunner: a compare-and-swap UPDATE claims the scan with a
// fresh run token (`run_token`, `run_until`, `attempts`); whatever replaces the scan or the
// document's text deletes the row (or replaces it), so the result's write, one immediate
// transaction, first checks the token is still the scan's and the document's hash the one the
// scan was made for: a stale transcription is never written. A temporary failure (the AI busy,
// down or unreachable, a timeout) lets the scan wait, longer each time (SCAN_BACKOFF_MS:
// `run_until` without a token is "not before"), and fails it the MAX_SCAN_RETRIES-th time; any
// other failure (a model that takes no pictures, an empty answer) fails it at once, and the page
// keeps the device's OCR text. Done or failed, the picture's file is deleted. A worker that died
// leaves a lease that runs out: run once more, then failed.
//
// Fair between families: at most one scan per family at a time, and a free slot goes to the
// family whose oldest waiting scan is the oldest.

import { and, asc, eq, isNull, lte, ne, notInArray, or, sql } from "drizzle-orm";
import { HttpError, randomToken } from "@/lib/api/http";
import { type AiEnv, familyModel } from "@/lib/assistant/routes";
import type { Db } from "@/lib/db";
import { aiSettings, kbDocuments, kbFolders, kbPageScans } from "@/lib/db/schema";
import { readImage } from "@/lib/meals/images/storage";
import { familyLocale } from "@/lib/notifications/locale";
import { moduleEnabled } from "@/lib/server-info";
import { TemporaryCardError } from "./card";
import { CARD_RESET, MAX_TEXT_BYTES, parseJsonArray } from "./documents";
import { deleteScanFiles } from "./scan-files";
import { TRANSCRIBE_TIMEOUT_MS, type TranscribeInput, transcribePage } from "./transcribe";

/** The lease a running scan holds (longer than it may take). */
export const SCAN_LEASE_MS = 5 * 60_000;
/** Runs of one scan before a lost one counts as failed. */
export const MAX_SCAN_ATTEMPTS = 2;
/** How long a scan waits after its 1st, 2nd, … temporary failure; the MAX_SCAN_RETRIES-th fails it. */
export const SCAN_BACKOFF_MS = [5 * 60_000, 30 * 60_000, 2 * 60 * 60_000, 2 * 60 * 60_000];
export const MAX_SCAN_RETRIES = 5;
/** The longest error a scan keeps. */
const MAX_ERROR = 200;

type ScanRow = typeof kbPageScans.$inferSelect;
type Due = Pick<ScanRow, "documentId" | "page" | "familyId" | "status" | "runToken" | "attempts" | "retries">;

/** What the claim reads: the picture and the hash it was made for. */
interface Claimed {
  path: string;
  hash: string;
}

export interface KnowledgeScanRunnerOptions {
  maxConcurrent?: number;
  /** Replaces transcribePage with the family's model (tests); null: the family's AI isn't set up. */
  transcriber?: (env: AiEnv, familyId: string, input: TranscribeInput, signal: AbortSignal) => Promise<string | null>;
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

const key = (s: Pick<ScanRow, "documentId" | "page">) => `${s.documentId}#${s.page}`;

/** The family's model reads the page; null when the family's AI isn't set up (any more). */
async function defaultTranscriber(env: AiEnv, familyId: string, input: TranscribeInput, signal: AbortSignal): Promise<string | null> {
  const model = await familyModel(env, familyId);
  if (!model) return null;
  return transcribePage(model.provider, input, env.modelNet, signal);
}

/** The scan as the tick read it: same status, same lease. */
function held(s: Due) {
  return and(
    eq(kbPageScans.documentId, s.documentId),
    eq(kbPageScans.page, s.page),
    eq(kbPageScans.status, s.status),
    s.runToken === null ? isNull(kbPageScans.runToken) : eq(kbPageScans.runToken, s.runToken),
  );
}

/** Still the scan this run claimed. */
function mine(s: Pick<ScanRow, "documentId" | "page">, run: Running) {
  return and(eq(kbPageScans.documentId, s.documentId), eq(kbPageScans.page, s.page), eq(kbPageScans.runToken, run.token));
}

function shortError(err: unknown): string {
  const message = err instanceof HttpError ? err.message : "Reading the page failed";
  return message.length > MAX_ERROR ? `${message.slice(0, MAX_ERROR - 1)}…` : message;
}

export class KnowledgeScanRunner {
  private readonly running = new Map<string, Running>();
  private readonly done = new Map<string, Promise<void>>();
  private stopped = false;
  private readonly db: Db;
  private readonly maxConcurrent: number;
  private readonly transcriber: NonNullable<KnowledgeScanRunnerOptions["transcriber"]>;
  private readonly now: () => Date;
  private readonly timeoutMs: number;
  private readonly leaseMs: number;
  private readonly log: (msg: string) => void;

  constructor(
    private readonly env: AiEnv,
    opts: KnowledgeScanRunnerOptions = {},
  ) {
    this.db = env.db;
    this.maxConcurrent = opts.maxConcurrent ?? Math.max(1, Number(process.env.KNOWLEDGE_SCAN_CONCURRENT) || 1);
    this.transcriber = opts.transcriber ?? defaultTranscriber;
    this.now = opts.now ?? (() => new Date());
    this.timeoutMs = opts.timeoutMs ?? TRANSCRIBE_TIMEOUT_MS + 30_000;
    this.leaseMs = opts.leaseMs ?? SCAN_LEASE_MS;
    this.log = opts.log ?? ((m) => console.log(`[knowledge] ${m}`));
  }

  get active(): number {
    return this.running.size;
  }

  /** Aborts the runs whose lease is gone, gives up on lost ones that ran too often, then claims
   *  and starts due scans of families with their AI set up; returns how many were started. Never
   *  throws. */
  tick(now = this.now()): number {
    if (this.stopped || !moduleEnabled("knowledge") || !moduleEnabled("assistant")) return 0;
    let started = 0;
    try {
      if (this.running.size) {
        for (const [k, run] of this.running) {
          const [documentId, page] = [k.slice(0, k.lastIndexOf("#")), Number(k.slice(k.lastIndexOf("#") + 1))];
          const row = this.db
            .select({ token: kbPageScans.runToken })
            .from(kbPageScans)
            .where(and(eq(kbPageScans.documentId, documentId), eq(kbPageScans.page, page)))
            .get();
          if (row?.token !== run.token) run.abort.abort("lost");
        }
      }
      const free = this.maxConcurrent - this.running.size;
      if (free <= 0) return 0;
      // Waiting and due, or running with a lease that ran out (its worker went away); of a
      // document that is still there as the scan saw it; forced or the family has scans on.
      const due = and(
        or(
          and(eq(kbPageScans.status, "waiting"), or(isNull(kbPageScans.runUntil), lte(kbPageScans.runUntil, now))),
          and(eq(kbPageScans.status, "running"), lte(kbPageScans.runUntil, now)),
        ),
        notInArray(kbDocuments.status, ["excluded", "missing"]),
        eq(kbDocuments.hash, kbPageScans.hash),
        or(eq(kbPageScans.forced, true), eq(kbFolders.aiScans, true)),
      );
      const busy = [...new Set([...this.running.values()].map((r) => r.familyId))];
      const families = this.db
        .select({ familyId: kbPageScans.familyId })
        .from(kbPageScans)
        .innerJoin(kbDocuments, eq(kbDocuments.id, kbPageScans.documentId))
        .innerJoin(kbFolders, eq(kbFolders.id, kbDocuments.folderId))
        .innerJoin(aiSettings, eq(aiSettings.familyId, kbPageScans.familyId))
        .where(
          and(
            due,
            ne(aiSettings.baseUrl, ""),
            ne(aiSettings.model, ""),
            busy.length ? notInArray(kbPageScans.familyId, busy) : undefined,
          ),
        )
        .groupBy(kbPageScans.familyId)
        .orderBy(sql`min(${kbPageScans.createdAt})`, kbPageScans.familyId)
        .limit(free)
        .all();
      for (const { familyId } of families) {
        if (this.running.size >= this.maxConcurrent) break;
        const scan = this.db
          .select({
            documentId: kbPageScans.documentId,
            page: kbPageScans.page,
            familyId: kbPageScans.familyId,
            status: kbPageScans.status,
            runToken: kbPageScans.runToken,
            attempts: kbPageScans.attempts,
            retries: kbPageScans.retries,
          })
          .from(kbPageScans)
          .innerJoin(kbDocuments, eq(kbDocuments.id, kbPageScans.documentId))
          .innerJoin(kbFolders, eq(kbFolders.id, kbDocuments.folderId))
          .where(and(eq(kbPageScans.familyId, familyId), due))
          .orderBy(asc(kbPageScans.createdAt), asc(kbPageScans.documentId), asc(kbPageScans.page))
          .limit(1)
          .get();
        if (!scan || this.running.has(key(scan))) continue;
        if (scan.status === "running" && scan.attempts >= MAX_SCAN_ATTEMPTS) {
          // The family's next one gets its turn with the next tick.
          this.interrupted(scan, now);
          continue;
        }
        if (this.start(scan, now)) started += 1;
      }
    } catch (err) {
      console.error("[knowledge] scan tick failed:", err);
    }
    return started;
  }

  private start(scan: Due, now: Date): boolean {
    const token = randomToken(32);
    const claimed = this.db
      .update(kbPageScans)
      .set({ status: "running", runToken: token, runUntil: new Date(now.getTime() + this.leaseMs), attempts: scan.attempts + 1, updatedAt: now })
      .where(held(scan))
      .returning({ path: kbPageScans.path, hash: kbPageScans.hash })
      .get();
    if (!claimed) return false;
    if (scan.status === "running") this.log(`reading page ${scan.page} of document ${scan.documentId} again (its worker went away)`);
    const run: Running = { abort: new AbortController(), token, familyId: scan.familyId };
    const k = key(scan);
    this.running.set(k, run);
    const p = this.run(scan, claimed, run)
      .catch((err) => console.error(`[knowledge] scan of page ${scan.page} of document ${scan.documentId} failed:`, err))
      .finally(() => {
        this.running.delete(k);
        this.done.delete(k);
        this.tick();
      });
    this.done.set(k, p);
    return true;
  }

  private async run(scan: Due, claimed: Claimed, run: Running): Promise<void> {
    const timeout = AbortSignal.timeout(this.timeoutMs);
    const signal = AbortSignal.any([run.abort.signal, timeout]);
    await new Promise((resolve) => setImmediate(resolve));
    const doc = this.db
      .select({ name: kbDocuments.name, text: kbDocuments.text, pages: kbDocuments.pages })
      .from(kbDocuments)
      .where(eq(kbDocuments.id, scan.documentId))
      .get();
    const image = await readImage(claimed.path);
    if (!doc || !image) {
      this.fail(scan, claimed, run, doc ? "The page's picture is gone" : "The document is gone");
      return;
    }
    let text: string | null;
    try {
      signal.throwIfAborted();
      const pages = parseJsonArray<unknown>(doc.text) ?? [];
      const hint = pages[scan.page - 1];
      const input: TranscribeInput = {
        lang: familyLocale(this.db, scan.familyId),
        name: doc.name,
        page: scan.page,
        pages: Math.max(doc.pages, scan.page),
        hint: typeof hint === "string" ? hint : "",
        image,
      };
      text = await this.transcriber(this.env, scan.familyId, input, signal);
      signal.throwIfAborted();
    } catch (err) {
      if (run.abort.signal.aborted) {
        // Lost its lease (replaced, the document's text replaced): the newer state stays.
        // Stopping: the next worker takes it over.
        if (this.stopped) this.release(scan, run);
        return;
      }
      const message = timeout.aborted ? "Reading the page took too long" : shortError(err);
      if (!(err instanceof HttpError) && !timeout.aborted) console.error(`[knowledge] scan of page ${scan.page} of document ${scan.documentId} failed:`, err);
      if (timeout.aborted || err instanceof TemporaryCardError) this.retryLater(scan, claimed, run, message);
      else this.fail(scan, claimed, run, message);
      return;
    }
    if (text === null) {
      // The family's AI went away meanwhile: back to waiting for it.
      this.release(scan, run);
      return;
    }
    const written = this.write(scan, claimed, run, text);
    if (written === "changed") this.log(`document ${scan.documentId} changed while page ${scan.page} was read, the text is dropped`);
  }

  /** Puts the transcription in place of the page's text (the document pending again, its card
   *  reset) and marks the scan done, only while the scan is this run's and the document has the
   *  hash it was made for; a document excluded or gone missing meanwhile: the scan waits again. */
  private write(scan: Due, claimed: Claimed, run: Running, text: string): "done" | "changed" | "waiting" | "failed" {
    const now = this.now();
    const outcome = this.db.transaction(
      (tx) => {
        const own = tx.select({ status: kbPageScans.status }).from(kbPageScans).where(mine(scan, run)).get();
        if (own?.status !== "running") return "changed" as const;
        const doc = tx
          .select({ hash: kbDocuments.hash, status: kbDocuments.status, text: kbDocuments.text, aiPages: kbDocuments.aiPages })
          .from(kbDocuments)
          .where(eq(kbDocuments.id, scan.documentId))
          .get();
        if (!doc || doc.hash !== claimed.hash) return "changed" as const;
        if (doc.status === "excluded" || doc.status === "missing") return "waiting" as const;
        const pages = (parseJsonArray<unknown>(doc.text) ?? []).map((p) => (typeof p === "string" ? p : ""));
        while (pages.length < scan.page) pages.push("");
        pages[scan.page - 1] = text;
        if (pages.reduce((n, p) => n + Buffer.byteLength(p, "utf8"), 0) > MAX_TEXT_BYTES) return "failed" as const;
        const aiPages = new Set((parseJsonArray<unknown>(doc.aiPages) ?? []).filter((p): p is number => Number.isSafeInteger(p)));
        aiPages.add(scan.page);
        tx.update(kbDocuments)
          .set({
            text: JSON.stringify(pages),
            pages: pages.length,
            aiPages: JSON.stringify([...aiPages].sort((a, b) => a - b)),
            status: "pending",
            error: null,
            indexedAt: null,
            runToken: null,
            runUntil: null,
            attempts: 0,
            ...CARD_RESET,
            updatedAt: now,
          })
          .where(eq(kbDocuments.id, scan.documentId))
          .run();
        tx.update(kbPageScans)
          .set({ status: "done", error: null, runToken: null, runUntil: null, updatedAt: now })
          .where(mine(scan, run))
          .run();
        return "done" as const;
      },
      { behavior: "immediate" },
    );
    if (outcome === "done") deleteScanFiles([claimed.path]);
    else if (outcome === "waiting") this.release(scan, run);
    else if (outcome === "failed") this.fail(scan, claimed, run, "The document's text would be too long");
    return outcome;
  }

  /** A failure for good: the page keeps the device's text; the picture goes. */
  private fail(scan: Due, claimed: Claimed, run: Running, message: string, extra: Partial<ScanRow> = {}): void {
    const changed = this.db
      .update(kbPageScans)
      .set({ status: "failed", error: message, runToken: null, runUntil: null, ...extra, updatedAt: this.now() })
      .where(mine(scan, run))
      .run().changes;
    if (changed) deleteScanFiles([claimed.path]);
  }

  /** A temporary failure: the scan waits SCAN_BACKOFF_MS (this claim not counted as a run), or
   *  fails after MAX_SCAN_RETRIES of them. */
  private retryLater(scan: Due, claimed: Claimed, run: Running, message: string): void {
    const retries = scan.retries + 1;
    if (retries >= MAX_SCAN_RETRIES) {
      this.fail(scan, claimed, run, message, { retries });
      return;
    }
    const wait = SCAN_BACKOFF_MS[Math.min(retries, SCAN_BACKOFF_MS.length) - 1];
    const now = this.now();
    const changed = this.db
      .update(kbPageScans)
      .set({
        status: "waiting",
        error: message,
        retries,
        attempts: scan.attempts,
        runToken: null,
        runUntil: new Date(now.getTime() + wait),
        updatedAt: now,
      })
      .where(mine(scan, run))
      .run().changes;
    if (changed) this.log(`page ${scan.page} of document ${scan.documentId} failed for now (${message}), tried again in ${Math.round(wait / 60_000)} min`);
  }

  /** Back to waiting, as if this worker had never claimed it. */
  private release(scan: Due, run: Running): void {
    this.db
      .update(kbPageScans)
      .set({ status: "waiting", runToken: null, runUntil: null, attempts: scan.attempts })
      .where(mine(scan, run))
      .run();
  }

  /** A lost run that ran too often: the scan failed, its picture deleted. */
  private interrupted(scan: Due, now: Date): void {
    const row = this.db
      .update(kbPageScans)
      .set({ status: "failed", error: "Reading the page was interrupted", runToken: null, runUntil: null, updatedAt: now })
      .where(held(scan))
      .returning({ path: kbPageScans.path })
      .get();
    if (row) {
      deleteScanFiles([row.path]);
      this.log(`page ${scan.page} of document ${scan.documentId} was interrupted ${scan.attempts} times, marked failed`);
    }
  }

  /** Waits for the running scans until all ended or `ms` passed. */
  async idle(ms = Infinity): Promise<void> {
    const until = Date.now() + ms;
    while (this.done.size && Date.now() < until) {
      await Promise.race([
        Promise.allSettled([...this.done.values()]),
        new Promise((r) => setTimeout(r, Math.min(50, until - Date.now()))),
      ]);
    }
  }

  /** Stops: the runs end where they are and their scans wait again for the next worker. */
  async stop(ms: number): Promise<void> {
    this.stopped = true;
    for (const run of this.running.values()) run.abort.abort("stop");
    await this.idle(ms);
  }
}

