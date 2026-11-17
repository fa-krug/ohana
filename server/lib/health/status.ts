// Where someone stands with each item of the schedule (browser-safe, pure): from their birthday,
// today and what was recorded.
//
// - done / skipped: recorded (a repeating or seasonal one: for the current period).
// - due: its window is open (`from` ≤ today ≤ `until`; adults' once-only ones stay due).
// - upcoming: its window opens later (`from`).
// - past: a child's window closed without a record. Shown quietly as "not recorded", never as
//   overdue: most of these happened before anyone used Ohana; one tap marks them all done.
// - unknown: a repeating one never recorded (when was the last tetanus shot?), or a second dose
//   whose first has no date.

import { type Lang, type ScheduleItem, SCHEDULE_BY_CODE, addAge, itemsFor, seasonOf } from "./schedule";

export type HealthStatus = "done" | "skipped" | "due" | "upcoming" | "past" | "unknown";
export type RecordStatus = "done" | "skipped";

export interface HealthRecord {
  id: string;
  code: string;
  /** When it was given / done; null: done, the date isn't known. */
  day: string | null;
  status: RecordStatus;
  note: string;
  /** The day it was recorded (stands in for a repeating one's unknown date). */
  recorded: string;
}

export interface ItemState {
  code: string;
  kind: ScheduleItem["kind"];
  title: string;
  detail: string;
  vaccines: string[];
  notAlwaysPaid: boolean;
  status: HealthStatus;
  /** The window (null: not known); a repeating one's `from` is when it's due next. */
  from: string | null;
  to: string | null;
  until: string | null;
  /** Again every so often (tetanus) or each autumn. */
  repeats: boolean;
  /** Its records, newest first. */
  records: Omit<HealthRecord, "code" | "recorded">[];
}

const dayOf = (r: HealthRecord) => r.day ?? r.recorded;
const newestFirst = (a: HealthRecord, b: HealthRecord) => dayOf(b).localeCompare(dayOf(a));

function windowState(from: string, to: string, until: string, today: string): HealthStatus {
  if (today < from) return "upcoming";
  if (today <= until) return "due";
  return "past";
}

/** One item's state. `byCode`: all of the person's records by code. */
export function itemState(
  item: ScheduleItem,
  birthday: string,
  today: string,
  byCode: Map<string, HealthRecord[]>,
  lang: Lang,
): ItemState {
  const records = [...(byCode.get(item.code) ?? [])].sort(newestFirst);
  const latest = records[0];
  let status: HealthStatus;
  let from: string | null = null;
  let to: string | null = null;
  let until: string | null = null;

  if (item.seasonal) {
    const season = seasonOf(today);
    const current = records.find((r) => dayOf(r) >= season.counts && dayOf(r) <= season.end);
    from = season.start;
    to = `${season.start.slice(0, 4)}-12-31`;
    until = season.end;
    status = current ? current.status : today < season.start ? "upcoming" : "due";
  } else if (item.every) {
    if (!latest) status = "unknown";
    else {
      from = addAge(dayOf(latest), item.every);
      status = today < from ? latest.status : "due";
    }
  } else if (item.after) {
    const first = [...(byCode.get(item.after) ?? [])].filter((r) => r.status === "done").sort(newestFirst)[0];
    if (first?.day) {
      from = addAge(first.day, item.from);
      to = addAge(first.day, item.to);
      until = addAge(first.day, item.until);
    }
    if (latest) status = latest.status;
    else if (!first) status = "upcoming";
    else if (!from || !to || !until) status = "unknown";
    else {
      status = windowState(from, to, until, today);
      // An adult's second dose is still worth having late.
      if (status === "past" && item.group === "adult") status = "due";
    }
  } else {
    from = addAge(birthday, item.from);
    if (item.group === "adult") {
      status = latest ? latest.status : today < from ? "upcoming" : "due";
    } else {
      to = addAge(birthday, item.to);
      until = addAge(birthday, item.until);
      status = latest ? latest.status : windowState(from, to, until, today);
    }
  }

  return {
    code: item.code,
    kind: item.kind,
    title: item.title[lang],
    detail: item.detail[lang],
    vaccines: item.vaccines?.[lang] ?? [],
    notAlwaysPaid: item.notAlwaysPaid ?? false,
    status,
    from,
    to,
    until,
    repeats: !!(item.every || item.seasonal),
    records: records.map(({ id, day, status: s, note }) => ({ id, day, status: s, note })),
  };
}

export interface PersonHealth {
  items: ItemState[];
  /** What to do next: the open window closing first, else the next to open. */
  next: ItemState | null;
  counts: { due: number; past: number; unknown: number };
}

/** Everything for someone born on `birthday` (null: nothing, the birthday is needed). */
export function personHealth(birthday: string | null, today: string, records: HealthRecord[], lang: Lang): PersonHealth {
  if (!birthday) return { items: [], next: null, counts: { due: 0, past: 0, unknown: 0 } };
  const byCode = new Map<string, HealthRecord[]>();
  for (const r of records) byCode.set(r.code, [...(byCode.get(r.code) ?? []), r]);
  const items = itemsFor(birthday, today).map((i) => itemState(i, birthday, today, byCode, lang));
  const count = (s: HealthStatus) => items.filter((i) => i.status === s).length;
  return { items, next: nextOf(items), counts: { due: count("due"), past: count("past"), unknown: count("unknown") } };
}

/** The due item whose window closes first (none: the earliest opened), else the next upcoming
 *  one with a date. */
export function nextOf(items: ItemState[]): ItemState | null {
  const due = items
    .filter((i) => i.status === "due")
    .sort((a, b) => (a.until ?? "9999").localeCompare(b.until ?? "9999") || (a.from ?? "").localeCompare(b.from ?? ""));
  if (due.length) return due[0];
  const upcoming = items.filter((i) => i.status === "upcoming" && i.from).sort((a, b) => a.from!.localeCompare(b.from!));
  return upcoming[0] ?? null;
}

/** Whether `code` is an item of the schedule. */
export const isCode = (code: unknown): code is string => typeof code === "string" && SCHEDULE_BY_CODE.has(code);
