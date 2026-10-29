// Scheduling helpers — replaces django-q's Schedule rows. Instead of a separate schedule
// table, each search carries `nextRunAt`; the in-process scheduler (or an external cron)
// runs searches whose `nextRunAt` has passed, then re-anchors it to wall-clock time so
// jitter never compounds. MINUTES/HOURLY/DAILY use interval + symmetric jitter; CRON is
// matched per-minute via `cronMatches`.

export type ScheduleType = "MINUTES" | "HOURLY" | "DAILY" | "CRON";

export interface Schedulable {
  scheduleType: string;
  scheduleMinutes: number | null;
}

function intervalMinutes(s: Schedulable): number | null {
  switch (s.scheduleType) {
    case "MINUTES":
      return s.scheduleMinutes && s.scheduleMinutes > 0 ? s.scheduleMinutes : 1;
    case "HOURLY":
      return 60;
    case "DAILY":
      return 1440;
    default:
      return null; // CRON (or unknown) is fired by cronMatches, not by an interval.
  }
}

function jitterPercent(): number {
  const raw = Number(process.env.SCHEDULE_JITTER_PERCENT ?? "15");
  if (!Number.isFinite(raw) || raw <= 0) return 0;
  return Math.min(raw, 90);
}

/**
 * Next run time for interval schedules, anchored to `from` with symmetric ± jitter.
 * Returns null for CRON/unknown types (they are matched, not intervaled).
 */
export function computeNextRunAt(
  s: Schedulable,
  from: Date = new Date(),
  rand: () => number = Math.random,
): Date | null {
  const interval = intervalMinutes(s);
  if (interval === null) return null;
  const pct = jitterPercent();
  const factor = pct === 0 ? 0 : (rand() * 2 - 1) * (pct / 100);
  const ms = interval * 60 * 1000 * (1 + factor);
  return new Date(from.getTime() + ms);
}

function parseField(field: string, min: number, max: number): Set<number> {
  const out = new Set<number>();
  for (const part of field.split(",")) {
    let step = 1;
    let range = part;
    const slash = part.indexOf("/");
    if (slash >= 0) {
      step = parseInt(part.slice(slash + 1), 10) || 1;
      range = part.slice(0, slash);
    }
    let lo = min;
    let hi = max;
    if (range !== "*" && range !== "") {
      const dash = range.indexOf("-");
      if (dash >= 0) {
        lo = parseInt(range.slice(0, dash), 10);
        hi = parseInt(range.slice(dash + 1), 10);
      } else {
        lo = hi = parseInt(range, 10);
      }
    }
    for (let v = lo; v <= hi; v += step) {
      if (v >= min && v <= max) out.add(v);
    }
  }
  return out;
}

/** Minimal 5-field cron matcher (minute hour day-of-month month day-of-week), local time. */
export function cronMatches(expr: string, date: Date): boolean {
  const fields = expr.trim().split(/\s+/);
  if (fields.length !== 5) return false;
  const [min, hr, dom, mon, dow] = fields;
  return (
    parseField(min, 0, 59).has(date.getMinutes()) &&
    parseField(hr, 0, 23).has(date.getHours()) &&
    parseField(dom, 1, 31).has(date.getDate()) &&
    parseField(mon, 1, 12).has(date.getMonth() + 1) &&
    parseField(dow, 0, 6).has(date.getDay())
  );
}
