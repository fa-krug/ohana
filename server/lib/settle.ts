// Waiting for a worker runner's jobs to end: the runners keep their running jobs' promises in a
// map that each job leaves when it ends, and new jobs may join while waiting. `JobRunner` is what
// the runners of the knowledge base, the recipe imports and the bank syncs share.

/** Waits until `running` is empty or `ms` passed, looking again at least every 50 ms. */
export async function settle(running: ReadonlyMap<string, Promise<void>>, ms = Infinity): Promise<void> {
  const until = Date.now() + ms;
  while (running.size && Date.now() < until) {
    await Promise.race([
      Promise.allSettled([...running.values()]),
      new Promise<void>((resolve) => {
        setTimeout(() => resolve(), Math.min(50, until - Date.now()));
      }),
    ]);
  }
}

/** A worker's runner of jobs that can be aborted: `running` by id while they run, `done` their
 *  promises (left when they end), `stopped` once `stop` was called. */
export abstract class JobRunner<Run extends { abort: AbortController }> {
  protected readonly running = new Map<string, Run>();
  protected readonly done = new Map<string, Promise<void>>();
  protected stopped = false;

  /** Waits for the running jobs until all ended or `ms` passed. */
  async idle(ms = Infinity): Promise<void> {
    await settle(this.done, ms);
  }

  /** Stops: the jobs end where they are ("stop") and wait again for the next worker (the bank
   *  syncs end as interrupted, never run again). */
  async stop(ms: number): Promise<void> {
    this.stopped = true;
    for (const run of this.running.values()) run.abort.abort("stop");
    await this.idle(ms);
  }
}
