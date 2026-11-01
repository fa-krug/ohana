import { Limiter } from "../src/limits";

describe("Limiter", () => {
  it("allows max hits per window, then says when there is room again", () => {
    const limiter = new Limiter([{ max: 3, windowMs: 60_000 }]);
    for (let i = 0; i < 3; i++) expect(limiter.take("k", 1000 + i)).toEqual({ ok: true });
    expect(limiter.take("k", 30_000)).toEqual({ ok: false, retryAfter: 31 });
    expect(limiter.take("other", 30_000)).toEqual({ ok: true });
    expect(limiter.take("k", 61_000)).toEqual({ ok: true });
  });

  it("takes n at once, all or nothing", () => {
    const limiter = new Limiter([{ max: 10, windowMs: 60_000 }]);
    expect(limiter.take("k", 0, 8).ok).toBe(true);
    expect(limiter.take("k", 0, 3).ok).toBe(false);
    expect(limiter.take("k", 0, 2).ok).toBe(true);
    expect(limiter.take("k", 0, 1).ok).toBe(false);
  });

  it("checks every rule before taking from any", () => {
    const limiter = new Limiter([
      { max: 2, windowMs: 60_000 },
      { max: 3, windowMs: 86_400_000 },
    ]);
    expect(limiter.take("k", 0).ok).toBe(true);
    expect(limiter.take("k", 1).ok).toBe(true);
    expect(limiter.take("k", 2)).toEqual({ ok: false, retryAfter: 60 });
    expect(limiter.take("k", 60_000).ok).toBe(true);
    // The day is full now: retry when the day's window ends.
    expect(limiter.take("k", 120_000)).toEqual({ ok: false, retryAfter: 86_400 - 120 });
  });

  it("prunes windows that ended", () => {
    const limiter = new Limiter([{ max: 1, windowMs: 60_000 }]);
    for (let i = 0; i < 100; i++) limiter.take(`k${i}`, 0);
    expect(limiter.size()).toBe(100);
    limiter.take("late", 120_000);
    expect(limiter.size()).toBe(1);
  });
});
