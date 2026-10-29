// The worker's side of appointments: find due searches, claim them atomically, run them,
// notify, re-anchor the schedule, prune old runs. Port of findmyappointment's
// scheduler.ts + tasks.ts (an in-process loop there; Ohana's worker process here).
//
// Claiming: a search is due when its interval `nextRunAt` has passed, its CRON expression
// matches the current minute (and `nextRunAt`, "not before", has passed), or someone
// pressed "Run now" (`runRequestedAt`). `claimSearch` is a compare-and-swap UPDATE that
// takes a lease (`lockedUntil`), clears the request and advances `nextRunAt` in one
// statement, so two workers (or two ticks) never run the same search at once.

import { and, eq, inArray, isNotNull, isNull, lt, lte, or } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { apptRuns, apptSearches } from "@/lib/db/schema";
import { notifyRun } from "./notify";
import { type PipelineOpts, type TriggeredBy, runPipeline } from "./pipeline";
import { computeNextRunAt, cronMatches } from "./scheduling";
import type { SearchRow } from "./searches";

const MINUTE = 60 * 1000;
const DAY = 24 * 60 * MINUTE;

function envNumber(name: string, fallback: number): number {
  const raw = Number(process.env[name]);
  return Number.isFinite(raw) && raw > 0 ? raw : fallback;
}

/** How long a claim holds; a worker that dies mid-run frees the search after this. */
export function leaseMs(): number {
  return envNumber("APPT_RUN_LEASE_MINUTES", 30) * MINUTE;
}

function startOfNextMinute(d: Date): Date {
  return new Date(Math.floor(d.getTime() / MINUTE) * MINUTE + MINUTE);
}

function scheduleDue(s: SearchRow, now: Date): boolean {
  if (!s.enabled) return false;
  if (s.scheduleType === "CRON") {
    return cronMatches(s.cron, now) && (s.nextRunAt === null || s.nextRunAt.getTime() <= now.getTime());
  }
  return s.nextRunAt !== null && s.nextRunAt.getTime() <= now.getTime();
}

/**
 * Searches that are due and not leased. Seeds `nextRunAt` for enabled interval searches
 * that have none, without firing them (as the source did on first sight).
 */
export function dueSearches(db: Db, now: Date): SearchRow[] {
  const candidates = db
    .select()
    .from(apptSearches)
    .where(
      and(
        or(isNull(apptSearches.lockedUntil), lte(apptSearches.lockedUntil, now)),
        or(eq(apptSearches.enabled, true), isNotNull(apptSearches.runRequestedAt)),
      ),
    )
    .all();
  const due: SearchRow[] = [];
  for (const s of candidates) {
    if (s.enabled && s.scheduleType !== "CRON" && s.nextRunAt === null) {
      const next = computeNextRunAt(s, now);
      if (next) {
        const res = db.update(apptSearches)
          .set({ nextRunAt: next })
          .where(and(eq(apptSearches.id, s.id), isNull(apptSearches.nextRunAt)))
          .run();
        // Keep the row in step with the database (claimSearch compares against it).
        s.nextRunAt = res.changes === 1 ? new Date(Math.floor(next.getTime() / 1000) * 1000) : s.nextRunAt;
      }
    }
    if (s.runRequestedAt !== null || scheduleDue(s, now)) due.push(s);
  }
  // "Run now" first, then the longest overdue.
  return due.sort(
    (a, b) =>
      Number(b.runRequestedAt !== null) - Number(a.runRequestedAt !== null) ||
      (a.nextRunAt?.getTime() ?? 0) - (b.nextRunAt?.getTime() ?? 0),
  );
}

export interface Claim {
  searchId: string;
  triggeredBy: TriggeredBy;
}

/** Takes the lease on a due search `s` (as read by `dueSearches`); null if someone else did. */
export function claimSearch(db: Db, s: SearchRow, now: Date): Claim | null {
  const manual = s.runRequestedAt !== null;
  const scheduled = scheduleDue(s, now);
  if (!manual && !scheduled) return null;
  const nextRunAt = scheduled
    ? s.scheduleType === "CRON"
      ? startOfNextMinute(now)
      : computeNextRunAt(s, now)
    : s.nextRunAt;
  const res = db
    .update(apptSearches)
    .set({ lockedUntil: new Date(now.getTime() + leaseMs()), runRequestedAt: null, nextRunAt })
    .where(
      and(
        eq(apptSearches.id, s.id),
        or(isNull(apptSearches.lockedUntil), lte(apptSearches.lockedUntil, now)),
        s.runRequestedAt ? eq(apptSearches.runRequestedAt, s.runRequestedAt) : isNull(apptSearches.runRequestedAt),
        s.nextRunAt ? eq(apptSearches.nextRunAt, s.nextRunAt) : isNull(apptSearches.nextRunAt),
      ),
    )
    .run();
  return res.changes === 1 ? { searchId: s.id, triggeredBy: manual ? "MANUAL" : "SCHEDULE" } : null;
}

/**
 * Runs a claimed search: pipeline, notification on success, then re-anchors the next
 * scheduled run to the finish time (so jitter never compounds) and releases the lease.
 */
export async function runClaimed(
  db: Db,
  claim: Claim,
  opts: Omit<PipelineOpts, "triggeredBy"> & { notify?: typeof notifyRun } = {},
): Promise<string | null> {
  try {
    const search = db.select().from(apptSearches).where(eq(apptSearches.id, claim.searchId)).get();
    if (!search) return null;
    const runId = await runPipeline(db, claim.searchId, { ...opts, triggeredBy: claim.triggeredBy });
    const run = db.select({ status: apptRuns.status }).from(apptRuns).where(eq(apptRuns.id, runId)).get();
    if (run?.status === "OK") {
      try {
        await (opts.notify ?? notifyRun)(db, runId);
      } catch (err) {
        console.error(`[appointments] notifying run ${runId} failed:`, err);
      }
    }
    if (claim.triggeredBy === "SCHEDULE" && search.scheduleType !== "CRON") {
      const current = db.select().from(apptSearches).where(eq(apptSearches.id, claim.searchId)).get();
      const next = current?.enabled ? computeNextRunAt(current, (opts.now ?? (() => new Date()))()) : null;
      if (next) db.update(apptSearches).set({ nextRunAt: next }).where(eq(apptSearches.id, claim.searchId)).run();
    }
    return runId;
  } finally {
    db.update(apptSearches).set({ lockedUntil: null }).where(eq(apptSearches.id, claim.searchId)).run();
  }
}

/** Releases leases (e.g. when the worker stops mid-run) so the searches aren't stuck. */
export function releaseSearches(db: Db, searchIds: string[]): void {
  if (searchIds.length === 0) return;
  db.update(apptSearches).set({ lockedUntil: null }).where(inArray(apptSearches.id, searchIds)).run();
}

/**
 * Runs left RUNNING by a worker that died (their search holds no live lease) become
 * ERROR, so the UI stops showing them as in progress.
 */
export function recoverStaleRuns(db: Db, now: Date): number {
  const stale = db
    .select({ id: apptRuns.id })
    .from(apptRuns)
    .innerJoin(apptSearches, eq(apptSearches.id, apptRuns.searchId))
    .where(
      and(
        eq(apptRuns.status, "RUNNING"),
        or(isNull(apptSearches.lockedUntil), lte(apptSearches.lockedUntil, now)),
      ),
    )
    .all()
    .map((r) => r.id);
  if (stale.length > 0) {
    db.update(apptRuns)
      .set({ status: "ERROR", errorMessage: "Interrupted: the worker stopped during the run.", finishedAt: now })
      .where(inArray(apptRuns.id, stale))
      .run();
  }
  return stale.length;
}

/** Deletes run history older than `days` (default APPT_RUN_RETENTION_DAYS, 30). */
export function pruneOldRuns(db: Db, now: Date, days?: number): number {
  const d = days ?? envNumber("APPT_RUN_RETENTION_DAYS", 30);
  const cutoff = new Date(now.getTime() - d * DAY);
  return db.delete(apptRuns).where(lt(apptRuns.startedAt, cutoff)).run().changes;
}
