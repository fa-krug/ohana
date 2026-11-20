import { describe, expect, it } from "vitest";
import { JobRunner, settle } from "@/lib/settle";

/** A promise and the function that ends it. */
function pending(): { promise: Promise<void>; end: () => void } {
  let end = () => {};
  const promise = new Promise<void>((resolve) => {
    end = resolve;
  });
  return { promise, end };
}

describe("settle", () => {
  it("returns at once when nothing runs", async () => {
    const started = Date.now();
    await settle(new Map());
    expect(Date.now() - started).toBeLessThan(50);
  });

  it("waits until every job has left the map, also those that join while waiting", async () => {
    const running = new Map<string, Promise<void>>();
    const first = pending();
    const second = pending();
    running.set("a", first.promise.then(() => void running.delete("a")));
    let settled = false;
    const waiting = settle(running).then(() => {
      settled = true;
    });
    running.set("b", second.promise.then(() => void running.delete("b")));
    first.end();
    await new Promise<void>((resolve) => {
      setTimeout(() => resolve(), 80);
    });
    expect(settled).toBe(false);
    second.end();
    await waiting;
    expect(settled).toBe(true);
    expect(running.size).toBe(0);
  });

  it("gives up after `ms` while a job still runs", async () => {
    const job = pending();
    const running = new Map([["a", job.promise]]);
    const started = Date.now();
    await settle(running, 60);
    expect(Date.now() - started).toBeGreaterThanOrEqual(55);
    expect(running.size).toBe(1);
    job.end();
  });
});

interface Run {
  abort: AbortController;
}

/** A runner whose jobs end when they are aborted. */
class TestRunner extends JobRunner<Run> {
  start(id: string): AbortController {
    const abort = new AbortController();
    this.running.set(id, { abort });
    const done = new Promise<void>((resolve) => abort.signal.addEventListener("abort", () => resolve())).then(() => {
      this.running.delete(id);
      this.done.delete(id);
    });
    this.done.set(id, done);
    return abort;
  }

  get isStopped(): boolean {
    return this.stopped;
  }
}

describe("JobRunner", () => {
  it("idle waits for the running jobs", async () => {
    const runner = new TestRunner();
    const abort = runner.start("a");
    setTimeout(() => abort.abort("done"), 30);
    await runner.idle(1000);
    expect(abort.signal.reason).toBe("done");
  });

  it("stop aborts every job with \"stop\" and waits for them", async () => {
    const runner = new TestRunner();
    const a = runner.start("a");
    const b = runner.start("b");
    await runner.stop(1000);
    expect(runner.isStopped).toBe(true);
    expect([a.signal.reason, b.signal.reason]).toEqual(["stop", "stop"]);
    await runner.idle(0);
  });
});
