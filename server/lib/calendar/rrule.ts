// Repeat rules of calendar events: RFC 5545 RRULE values ("FREQ=WEEKLY;BYDAY=MO,WE"), checked
// and expanded on plain days (no times, no time zones: every date is a UTC midnight). Allowed
// parts: FREQ (DAILY | WEEKLY | MONTHLY | YEARLY, required), INTERVAL, COUNT, UNTIL (a date
// YYYYMMDD, inclusive), BYDAY (ordinals like 2MO / -1FR only with MONTHLY and YEARLY),
// BYMONTHDAY, BYMONTH, BYYEARDAY, BYWEEKNO, BYSETPOS and WKST, combined as RFC 5545 allows.
// The first occurrence is always DTSTART (the event's first day), as in iCalendar, and it counts
// for COUNT. Expansion is bounded: it stops after a fixed amount of work, so a rule that never
// (or seldom) matches can't run away.

import { HttpError } from "@/lib/api/http";
import { isValidDate } from "./dates";

export type Freq = "DAILY" | "WEEKLY" | "MONTHLY" | "YEARLY";

export interface WeekdayNum {
  /** 0 = Monday … 6 = Sunday */
  wd: number;
  /** The ordinal (2MO: 2, -1FR: -1); 0: every such weekday. */
  n: number;
}

export interface Rule {
  freq: Freq;
  interval: number;
  count: number | null;
  /** "YYYY-MM-DD", inclusive. */
  until: string | null;
  byDay: WeekdayNum[] | null;
  byMonthDay: number[] | null;
  byMonth: number[] | null;
  byYearDay: number[] | null;
  byWeekNo: number[] | null;
  bySetPos: number[] | null;
  /** 0 = Monday … 6 = Sunday */
  wkst: number;
}

const FREQS: Freq[] = ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"];
const WEEKDAYS = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"];
const PARTS = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH", "BYYEARDAY", "BYWEEKNO", "BYSETPOS", "WKST"];
const MAX_LENGTH = 500;
const MAX_INTERVAL = 1000;
const MAX_COUNT = 100_000;
/** Candidate days looked at per expansion at most. */
const MAX_WORK = 1_000_000;

const bad = (message: string) => new HttpError(400, `rrule: ${message}`);

/** The rule as stored: trimmed and upper-cased. 400 unless it is a valid rule. */
export function normalizeRrule(raw: unknown): string {
  if (typeof raw !== "string") throw bad("must be a string like FREQ=WEEKLY");
  const s = raw.trim().toUpperCase();
  parseRrule(s);
  return s;
}

function intList(value: string, key: string, min: number, max: number, nonZero = true): number[] {
  const out = value.split(",").map((v) => {
    if (!/^[+-]?\d{1,4}$/.test(v)) throw bad(`${key} must be a list of numbers`);
    const n = Number(v);
    if (n < -max || n > max || (nonZero && n === 0) || (min > 0 && n < min)) {
      throw bad(`${key} out of range: ${v}`);
    }
    return n;
  });
  return [...new Set(out)];
}

/** Parses a stored (upper-case) rule; 400 for anything RFC 5545 or Ohana doesn't allow. */
export function parseRrule(s: string): Rule {
  if (!s) throw bad("must not be empty");
  if (s.length > MAX_LENGTH) throw bad("is too long");
  const parts = new Map<string, string>();
  for (const part of s.split(";")) {
    const i = part.indexOf("=");
    const key = i > 0 ? part.slice(0, i) : part;
    const value = i > 0 ? part.slice(i + 1) : "";
    if (!PARTS.includes(key)) throw bad(`unknown part "${key}"`);
    if (parts.has(key)) throw bad(`${key} is given twice`);
    if (!value) throw bad(`${key} needs a value`);
    parts.set(key, value);
  }
  const freq = parts.get("FREQ") as Freq | undefined;
  if (!freq) throw bad("FREQ is required");
  if (!FREQS.includes(freq)) throw bad("FREQ must be DAILY, WEEKLY, MONTHLY or YEARLY");

  let interval = 1;
  if (parts.has("INTERVAL")) {
    const v = parts.get("INTERVAL")!;
    if (!/^\d{1,4}$/.test(v) || Number(v) < 1 || Number(v) > MAX_INTERVAL) throw bad("INTERVAL must be a positive number");
    interval = Number(v);
  }
  let count: number | null = null;
  if (parts.has("COUNT")) {
    const v = parts.get("COUNT")!;
    if (!/^\d{1,6}$/.test(v) || Number(v) < 1 || Number(v) > MAX_COUNT) throw bad("COUNT must be a positive number");
    count = Number(v);
  }
  let until: string | null = null;
  if (parts.has("UNTIL")) {
    const v = parts.get("UNTIL")!;
    const date = /^\d{8}$/.test(v) ? `${v.slice(0, 4)}-${v.slice(4, 6)}-${v.slice(6, 8)}` : "";
    if (!isValidDate(date)) throw bad("UNTIL must be a date YYYYMMDD");
    until = date;
  }
  if (count !== null && until !== null) throw bad("COUNT and UNTIL can't be combined");

  const wkstRaw = parts.get("WKST");
  if (wkstRaw !== undefined && !WEEKDAYS.includes(wkstRaw)) throw bad("WKST must be a weekday (MO … SU)");
  const wkst = wkstRaw ? WEEKDAYS.indexOf(wkstRaw) : 0;

  const byWeekNo = parts.has("BYWEEKNO") ? intList(parts.get("BYWEEKNO")!, "BYWEEKNO", 0, 53) : null;
  if (byWeekNo && freq !== "YEARLY") throw bad("BYWEEKNO only goes with FREQ=YEARLY");
  const byYearDay = parts.has("BYYEARDAY") ? intList(parts.get("BYYEARDAY")!, "BYYEARDAY", 0, 366) : null;
  if (byYearDay && freq !== "YEARLY") throw bad("BYYEARDAY only goes with FREQ=YEARLY");
  const byMonthDay = parts.has("BYMONTHDAY") ? intList(parts.get("BYMONTHDAY")!, "BYMONTHDAY", 0, 31) : null;
  if (byMonthDay && freq === "WEEKLY") throw bad("BYMONTHDAY doesn't go with FREQ=WEEKLY");
  const byMonth = parts.has("BYMONTH") ? intList(parts.get("BYMONTH")!, "BYMONTH", 1, 12) : null;

  let byDay: WeekdayNum[] | null = null;
  if (parts.has("BYDAY")) {
    const seen = new Set<string>();
    byDay = [];
    for (const v of parts.get("BYDAY")!.split(",")) {
      const m = /^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$/.exec(v);
      if (!m) throw bad(`BYDAY can't hold "${v}"`);
      const n = m[1] ? Number(m[1]) : 0;
      if (m[1] && n === 0) throw bad(`BYDAY can't hold "${v}"`);
      if (n !== 0) {
        if (freq !== "MONTHLY" && freq !== "YEARLY") throw bad("BYDAY ordinals (like 2MO) only go with MONTHLY or YEARLY");
        if (freq === "YEARLY" && byWeekNo) throw bad("BYDAY ordinals don't go with BYWEEKNO");
        if (Math.abs(n) > 53) throw bad(`BYDAY ordinal out of range: ${v}`);
      }
      const key = `${n}${m[2]}`;
      if (!seen.has(key)) byDay.push({ wd: WEEKDAYS.indexOf(m[2]), n });
      seen.add(key);
    }
  }
  const bySetPos = parts.has("BYSETPOS") ? intList(parts.get("BYSETPOS")!, "BYSETPOS", 0, 366) : null;
  if (bySetPos && !byDay && !byMonthDay && !byMonth && !byYearDay && !byWeekNo) {
    throw bad("BYSETPOS needs another BY… part");
  }
  return { freq, interval, count, until, byDay, byMonthDay, byMonth, byYearDay, byWeekNo, bySetPos, wkst };
}

/** The rule with its end changed: COUNT and UNTIL taken out, then `until` ("YYYY-MM-DD") or
 *  `count` set; the other parts stay as they were. */
export function withEnd(rrule: string, end: { until?: string; count?: number }): string {
  const kept = rrule.split(";").filter((p) => !p.startsWith("COUNT=") && !p.startsWith("UNTIL="));
  if (end.until) kept.push(`UNTIL=${end.until.replace(/-/g, "")}`);
  else if (end.count) kept.push(`COUNT=${end.count}`);
  return kept.join(";");
}

// ---------------------------------------------------------------- days as numbers

const DAY_MS = 86_400_000;
const num = (date: string) => Date.UTC(+date.slice(0, 4), +date.slice(5, 7) - 1, +date.slice(8, 10)) / DAY_MS;
const ymd = (n: number) => {
  const d = new Date(n * DAY_MS);
  return { y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: d.getUTCDate() };
};
const iso = (n: number) => new Date(n * DAY_MS).toISOString().slice(0, 10);
/** 0 = Monday … 6 = Sunday (1970-01-01, day 0, was a Thursday). */
const weekdayOf = (n: number) => (((n + 3) % 7) + 7) % 7;
const dayOf = (y: number, m: number, d: number) => Date.UTC(y, m - 1, d) / DAY_MS;
const daysInMonth = (y: number, m: number) => new Date(Date.UTC(y, m, 0)).getUTCDate();
const isLeap = (y: number) => (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
const MAX_YEAR = 9999;

/** The first day of week 1 of year `y` (the first week with at least 4 days in the year). */
function week1Start(y: number, wkst: number): number {
  const jan1 = dayOf(y, 1, 1);
  const off = (weekdayOf(jan1) - wkst + 7) % 7;
  return off <= 3 ? jan1 - off : jan1 + (7 - off);
}

/** Whether day `n` of year `y` is in one of `weeks` (positive or negative week numbers). */
function inWeeks(n: number, y: number, weeks: number[], wkst: number): boolean {
  const start = week1Start(y, wkst);
  const next = week1Start(y + 1, wkst);
  let no: number;
  let neg: number;
  if (n < start) {
    // The last week of the year before.
    const prevWeeks = (start - week1Start(y - 1, wkst)) / 7;
    no = prevWeeks;
    neg = -1;
  } else if (n >= next) {
    // Week 1 of the next year.
    const nextWeeks = (week1Start(y + 2, wkst) - next) / 7;
    no = 1;
    neg = -nextWeeks;
  } else {
    no = Math.floor((n - start) / 7) + 1;
    neg = no - (next - start) / 7 - 1;
  }
  return weeks.includes(no) || weeks.includes(neg);
}

interface Expander {
  rule: Rule;
  start: number;
  byDay: WeekdayNum[] | null;
  byMonthDay: number[] | null;
  byMonth: number[] | null;
}

function expander(rule: Rule, dtstart: string): Expander {
  const start = num(dtstart);
  const s = ymd(start);
  let { byDay, byMonthDay, byMonth } = rule;
  // Without a day part the rule repeats DTSTART's day (RFC 5545, as python-dateutil does it).
  if (!rule.byWeekNo && !rule.byYearDay && !byMonthDay && !byDay) {
    if (rule.freq === "YEARLY") {
      byMonth ??= [s.m];
      byMonthDay = [s.d];
    } else if (rule.freq === "MONTHLY") {
      byMonthDay = [s.d];
    } else if (rule.freq === "WEEKLY") {
      byDay = [{ wd: weekdayOf(start), n: 0 }];
    }
  }
  return { rule, start, byDay, byMonthDay, byMonth };
}

/** The days of period `k` (0: the one DTSTART is in) that the rule picks, sorted, and the
 *  period's first day. */
function periodDays(x: Expander, k: number): { first: number; days: number[] } | null {
  const { rule, start } = x;
  const s = ymd(start);
  let candidates: number[];
  let first: number;
  switch (rule.freq) {
    case "DAILY":
      first = start + k * rule.interval;
      candidates = [first];
      break;
    case "WEEKLY": {
      const week0 = start - ((weekdayOf(start) - rule.wkst + 7) % 7);
      first = week0 + 7 * k * rule.interval;
      candidates = [0, 1, 2, 3, 4, 5, 6].map((i) => first + i);
      break;
    }
    case "MONTHLY": {
      const index = s.y * 12 + (s.m - 1) + k * rule.interval;
      const y = Math.floor(index / 12);
      const m = (index % 12) + 1;
      if (y > MAX_YEAR) return null;
      first = dayOf(y, m, 1);
      candidates = Array.from({ length: daysInMonth(y, m) }, (_, i) => first + i);
      break;
    }
    case "YEARLY": {
      const y = s.y + k * rule.interval;
      if (y > MAX_YEAR) return null;
      first = dayOf(y, 1, 1);
      candidates = Array.from({ length: isLeap(y) ? 366 : 365 }, (_, i) => first + i);
      break;
    }
  }
  if (ymd(first).y > MAX_YEAR) return null;
  let days = candidates.filter((n) => matches(x, n));
  if (rule.bySetPos) {
    const picked = new Set<number>();
    for (const p of rule.bySetPos) {
      const i = p > 0 ? p - 1 : days.length + p;
      if (i >= 0 && i < days.length) picked.add(days[i]);
    }
    days = [...picked].sort((a, b) => a - b);
  }
  return { first, days };
}

function matches(x: Expander, n: number): boolean {
  const { rule, byDay, byMonthDay, byMonth } = x;
  const { y, m, d } = ymd(n);
  if (byMonth && !byMonth.includes(m)) return false;
  if (rule.byWeekNo && !inWeeks(n, y, rule.byWeekNo, rule.wkst)) return false;
  if (rule.byYearDay) {
    const yd = n - dayOf(y, 1, 1) + 1;
    const neg = yd - (isLeap(y) ? 366 : 365) - 1;
    if (!rule.byYearDay.includes(yd) && !rule.byYearDay.includes(neg)) return false;
  }
  if (byMonthDay) {
    const neg = d - daysInMonth(y, m) - 1;
    if (!byMonthDay.includes(d) && !byMonthDay.includes(neg)) return false;
  }
  if (byDay) {
    const wd = weekdayOf(n);
    // Ordinals count within the month (MONTHLY, or YEARLY with BYMONTH), else the year.
    const inMonth = rule.freq === "MONTHLY" || (rule.freq === "YEARLY" && !!rule.byMonth);
    const scopeFirst = inMonth ? dayOf(y, m, 1) : dayOf(y, 1, 1);
    const scopeLast = inMonth ? dayOf(y, m, daysInMonth(y, m)) : dayOf(y, 12, 31);
    const pos = Math.floor((n - scopeFirst) / 7) + 1;
    const neg = -(Math.floor((scopeLast - n) / 7) + 1);
    if (!byDay.some((b) => b.wd === wd && (b.n === 0 || b.n === pos || b.n === neg))) return false;
  }
  return true;
}

/** How many periods lie between DTSTART's and day `n`'s (to skip ahead without COUNT). */
function periodsBefore(x: Expander, n: number): number {
  const { rule, start } = x;
  if (n <= start) return 0;
  const a = ymd(start);
  const b = ymd(n);
  switch (rule.freq) {
    case "DAILY":
      return Math.floor((n - start) / rule.interval);
    case "WEEKLY":
      return Math.floor((n - start) / 7 / rule.interval);
    case "MONTHLY":
      return Math.floor((b.y * 12 + b.m - (a.y * 12 + a.m)) / rule.interval);
    case "YEARLY":
      return Math.floor((b.y - a.y) / rule.interval);
  }
}

/**
 * The occurrences (original dates, "YYYY-MM-DD") of the rule starting at `dtstart` from `from`
 * to `to` (inclusive), sorted, at most `limit`. DTSTART is always the first one.
 */
export function expandRule(rule: Rule, dtstart: string, from: string, to: string, limit = 5000): string[] {
  const x = expander(rule, dtstart);
  const lo = num(from);
  let hi = num(to);
  if (rule.until) hi = Math.min(hi, num(rule.until));
  const out: string[] = [];
  if (hi < x.start || hi < lo || limit <= 0) return out;
  if (x.start >= lo) out.push(dtstart);
  let produced = 1;
  if (rule.count === 1 || out.length >= limit) return out;
  // Without COUNT, nothing before `from` matters: start a period early to be safe.
  let k = rule.count === null ? Math.max(0, periodsBefore(x, lo) - 1) : 0;
  let work = 0;
  for (; work < MAX_WORK; k++) {
    const period = periodDays(x, k);
    if (!period || period.first > hi) break;
    work += rule.freq === "YEARLY" ? 366 : rule.freq === "MONTHLY" ? 31 : rule.freq === "WEEKLY" ? 7 : 1;
    for (const n of period.days) {
      if (n <= x.start) continue;
      if (n > hi) return out;
      produced++;
      if (n >= lo) {
        out.push(iso(n));
        if (out.length >= limit) return out;
      }
      if (rule.count !== null && produced >= rule.count) return out;
    }
  }
  return out;
}

/** Whether `date` is an occurrence of the rule starting at `dtstart` (exdates aside). */
export function isRuleOccurrence(rule: Rule, dtstart: string, date: string): boolean {
  return expandRule(rule, dtstart, date, date, 1).length === 1;
}
