// Rate limits in memory (one instance; they don't need to survive a restart). Fixed windows:
// a key's window starts with its first hit and lasts `windowMs`; within it at most `max` hits.
// Expired windows are pruned at most once a minute, so the maps only hold recent keys.

export type Rule = { max: number; windowMs: number };

export type Taken = { ok: true } | { ok: false; retryAfter: number };

type Window = { start: number; count: number };

const PRUNE_EVERY_MS = 60_000;

export class Limiter {
  private readonly windows: Map<string, Window>[];
  private lastPrune = 0;

  /** Several rules apply together (e.g. 30 a minute and 500 a day). */
  constructor(private readonly rules: Rule[]) {
    this.windows = rules.map(() => new Map());
  }

  /**
   * Takes `n` hits for `key` when every rule has room for them; otherwise takes nothing and
   * says when (seconds) the fullest rule has room again.
   */
  take(key: string, now: number, n = 1): Taken {
    this.prune(now);
    let retryAfter = 0;
    const current = this.rules.map((rule, i) => {
      let w = this.windows[i].get(key);
      if (w && now - w.start >= rule.windowMs) w = undefined;
      if ((w?.count ?? 0) + n > rule.max) {
        // A window that can never hold n (n > max) still answers with its end.
        const end = w ? w.start + rule.windowMs : now + rule.windowMs;
        retryAfter = Math.max(retryAfter, Math.ceil((end - now) / 1000));
      }
      return w;
    });
    if (retryAfter > 0) return { ok: false, retryAfter: Math.max(1, retryAfter) };
    this.rules.forEach((_, i) => {
      const w = current[i];
      if (w) w.count += n;
      else this.windows[i].set(key, { start: now, count: n });
    });
    return { ok: true };
  }

  /** How many keys are held (for tests). */
  size(): number {
    return Math.max(0, ...this.windows.map((m) => m.size));
  }

  private prune(now: number): void {
    if (now - this.lastPrune < PRUNE_EVERY_MS) return;
    this.lastPrune = now;
    this.rules.forEach((rule, i) => {
      for (const [key, w] of this.windows[i]) {
        if (now - w.start >= rule.windowMs) this.windows[i].delete(key);
      }
    });
  }
}

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;

export type LimitsConfig = {
  /** /v1/register per IP. */
  register: Rule[];
  /** Messages per IP across /v1/send requests. */
  sendPerIp: Rule[];
  /** Messages per device (keyed on the APNs token). */
  perDevice: Rule[];
};

export const DEFAULT_LIMITS: LimitsConfig = {
  register: [{ max: 30, windowMs: MINUTE }],
  sendPerIp: [{ max: 1000, windowMs: MINUTE }],
  perDevice: [
    { max: 30, windowMs: MINUTE },
    { max: 500, windowMs: DAY },
  ],
};
