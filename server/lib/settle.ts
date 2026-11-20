// Waiting for a worker runner's jobs to end (its `idle(ms)`): the runners keep their running jobs'
// promises in a map that each job leaves when it ends, and new jobs may join while waiting.

/** Waits until `running` is empty or `ms` passed, looking again at least every 50 ms. */
export async function settle(running: ReadonlyMap<string, Promise<void>>, ms = Infinity): Promise<void> {
  const until = Date.now() + ms;
  while (running.size && Date.now() < until) {
    await Promise.race([
      Promise.allSettled([...running.values()]),
      new Promise<void>((resolve) => {
        setTimeout(resolve, Math.min(50, until - Date.now()));
      }),
    ]);
  }
}
