// Date helpers working on ISO calendar dates ("YYYY-MM-DD") in UTC (from family-planner's
// _shared/dates.ts).

const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const DAY_MS = 86_400_000;

export function isValidDate(s: unknown): s is string {
  if (typeof s !== "string") return false;
  const m = DATE_RE.exec(s);
  if (!m) return false;
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  return d.getUTCFullYear() === +m[1] && d.getUTCMonth() === +m[2] - 1 && d.getUTCDate() === +m[3];
}

export function toDate(s: string): Date {
  return new Date(s + "T00:00:00Z");
}

export function formatDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

export function addDays(s: string, n: number): string {
  return formatDate(new Date(toDate(s).getTime() + n * DAY_MS));
}

/** Days between two dates (b - a). */
export function diffDays(a: string, b: string): number {
  return Math.round((toDate(b).getTime() - toDate(a).getTime()) / DAY_MS);
}

/** Inclusive list of dates from `from` to `to` (order-independent). */
export function dateRange(from: string, to: string): string[] {
  if (from > to) [from, to] = [to, from];
  const out: string[] = [];
  for (let d = from; d <= to; d = addDays(d, 1)) out.push(d);
  return out;
}

/** 0 = Sunday … 6 = Saturday */
export function weekday(s: string): number {
  return toDate(s).getUTCDay();
}

export function isWeekend(s: string): boolean {
  const w = weekday(s);
  return w === 0 || w === 6;
}

/** Groups sorted dates into runs of consecutive days. */
export function consecutiveRuns(sorted: string[]): string[][] {
  const runs: string[][] = [];
  for (const d of sorted) {
    const last = runs[runs.length - 1];
    if (last && addDays(last[last.length - 1], 1) === d) last.push(d);
    else runs.push([d]);
  }
  return runs;
}
