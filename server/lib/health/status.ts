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
// - optional: one that's not recommended at this age but can be had (flu, COVID-19 before 60),
//   without a record for the current period: never due, never told about.

import { type Lang, type ScheduleItem, SCHEDULE_BY_CODE, addAge, isOptional, itemsFor, seasonOf } from "./schedule";

export type HealthStatus = "done" | "skipped" | "due" | "upcoming" | "past" | "unknown" | "optional";
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
  /** Not recommended at this age, but can be had (flu, COVID-19 before 60). */
  optional: boolean;
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

/** Where an item stands, and its window. */
interface Standing {
  status: HealthStatus;
  from: string | null;
  to: string | null;
  until: string | null;
}

const NO_WINDOW = { from: null, to: null, until: null };

const seasonWindow = (season: ReturnType<typeof seasonOf>) => ({
  from: season.start,
  to: `${season.start.slice(0, 4)}-12-31`,
  until: season.end,
});

/** Flu, COVID-19: the current autumn season's record (then the next season's window), else due
 *  from 1 October; `optional`: never due. */
function seasonal(records: HealthRecord[], today: string, optional: boolean): Standing {
  const season = seasonOf(today);
  const current = records.find((r) => dayOf(r) >= season.counts && dayOf(r) <= season.end);
  if (current) return { status: current.status, ...seasonWindow(seasonOf(`${Number(season.start.slice(0, 4)) + 1}-06-01`)) };
  const status = optional ? "optional" : today < season.start ? "upcoming" : "due";
  return { status, ...seasonWindow(season) };
}

/** Tetanus: due again `every` after the newest record; never recorded: unknown. */
function repeating(item: ScheduleItem, latest: HealthRecord | undefined, today: string): Standing {
  if (!latest) return { status: "unknown", ...NO_WINDOW };
  const from = addAge(dayOf(latest), item.every!);
  return { status: today < from ? latest.status : "due", ...NO_WINDOW, from };
}

/** A second dose: its window counts from the first one's day. */
function secondDose(
  item: ScheduleItem,
  latest: HealthRecord | undefined,
  byCode: Map<string, HealthRecord[]>,
  today: string,
): Standing {
  const first = [...(byCode.get(item.after!) ?? [])].filter((r) => r.status === "done").sort(newestFirst)[0];
  const window = first?.day
    ? { from: addAge(first.day, item.from), to: addAge(first.day, item.to), until: addAge(first.day, item.until) }
    : NO_WINDOW;
  if (latest) return { status: latest.status, ...window };
  if (!first) return { status: "upcoming", ...window };
  if (!window.from || !window.to || !window.until) return { status: "unknown", ...window };
  const status = windowState(window.from, window.to, window.until, today);
  // An adult's second dose is still worth having late.
  return { status: status === "past" && item.group === "adult" ? "due" : status, ...window };
}

/** By age: a child's window, or an adult's from an age on (due until recorded). */
function byAge(item: ScheduleItem, latest: HealthRecord | undefined, birthday: string, today: string): Standing {
  const from = addAge(birthday, item.from);
  if (item.group === "adult") {
    return { status: latest ? latest.status : today < from ? "upcoming" : "due", ...NO_WINDOW, from };
  }
  const to = addAge(birthday, item.to);
  const until = addAge(birthday, item.until);
  return { status: latest ? latest.status : windowState(from, to, until, today), from, to, until };
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
  const optional = isOptional(item, birthday, today);
  const { status, from, to, until } = item.seasonal
    ? seasonal(records, today, optional)
    : item.every
      ? repeating(item, latest, today)
      : item.after
        ? secondDose(item, latest, byCode, today)
        : byAge(item, latest, birthday, today);

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
    optional,
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
