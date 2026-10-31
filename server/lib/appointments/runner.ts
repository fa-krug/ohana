// The worker's appointment loop: every tick it claims due searches and starts them
// WITHOUT awaiting, at most `maxConcurrent` at once, so a slow or hanging scrape never
// blocks the loop (or the worker's other jobs). Every request of a scrape has a timeout
// (http.ts), so a run always ends.

import type { Db } from "@/lib/db";
import { claimSearch, dueSearches, pruneOldRuns, recoverStaleRuns, releaseSearches, runClaimed } from "./tasks";

type RunOpts = Parameters<typeof runClaimed>[2];

const DAY = 24 * 60 * 60 * 1000;

export class SearchRunner {
  private readonly running = new Map<string, Promise<unknown>>();
  private lastPrune = 0;

  constructor(
    private readonly db: Db,
    private readonly maxConcurrent: number = Math.max(1, Number(process.env.APPT_MAX_CONCURRENT) || 2),
    private readonly log: (msg: string) => void = (m) => console.log(`[appointments] ${m}`),
    /** Test injection (fake sources / notifier). */
    private readonly runOpts: RunOpts = {},
  ) {}

  /** Call once at start: marks runs a previous worker left RUNNING as interrupted. */
  start(now: Date): void {
    const n = recoverStaleRuns(this.db, now);
    if (n > 0) this.log(`marked ${n} interrupted run(s)`);
  }

  get active(): number {
    return this.running.size;
  }

  /** Claims and starts due searches; returns how many were started. Never throws. */
  tick(now: Date): number {
    let started = 0;
    try {
      if (now.getTime() - this.lastPrune > DAY) {
        this.lastPrune = now.getTime();
        const pruned = pruneOldRuns(this.db, now);
        if (pruned > 0) this.log(`pruned ${pruned} old run(s)`);
      }
      for (const s of dueSearches(this.db, now)) {
        if (this.running.size >= this.maxConcurrent) break;
        if (this.running.has(s.id)) continue;
        const claim = claimSearch(this.db, s, now);
        if (!claim) continue;
        started += 1;
        this.log(`running "${s.name}" (${claim.triggeredBy.toLowerCase()})`);
        const p = runClaimed(this.db, claim, this.runOpts)
          .catch((err) => console.error(`[appointments] search ${s.id} failed:`, err))
          .finally(() => this.running.delete(s.id));
        this.running.set(s.id, p);
      }
    } catch (err) {
      console.error("[appointments] tick failed:", err);
    }
    return started;
  }

  /** Waits up to `ms` for running searches, then frees the leases of those still running. */
  async stop(ms: number): Promise<void> {
    const all = Promise.allSettled([...this.running.values()]);
    await Promise.race([all, new Promise((r) => setTimeout(r, ms))]);
    releaseSearches(this.db, [...this.running.keys()]);
  }
}
