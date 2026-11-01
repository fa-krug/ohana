// Events on calendar days (phase 7): booked doctor's appointments (from a slot of an appointment
// search), events the app imported from Apple Calendar and events added by hand or by the
// assistant. They sit next to the year grid's entries (no type, no role, no coverage) and show up
// on the calendar, the overview and in the search.
//
// An event covers one day or several (`day` .. `endDay`), all day or at a time, and may repeat
// (`rrule`, an RFC 5545 RRULE value, expanded by ./rrule.ts; `day` is the first occurrence).
// A series keeps the occurrences it lost (`exdates`) and changed single occurrences as rows of
// their own (`seriesId` + `occurrence`, the date they replace). Readers get occurrences
// (`PublicEvent`: what calendars show, addressed as id + occurrence); editors and the Apple sync
// get whole series (`EventSeries`).
//
// Events the app imported from an Apple Calendar (EventKit) have source "apple" and the Apple
// event's identifier in `source_item` (`externalId`), so a second device syncing the same
// calendar links them instead of importing them again; otherwise they are manual events.
//
// REST (family API, /families/{id}/…):
// GET    /events?from=&to= | ?year=      occurrences overlapping the range (max. 3 years)
// GET    /events?raw=1                   every series / single event (EventSeries)
// GET    /events/{id}                    one series (EventSeries)
// POST   /events                         a new event or series (201 EventSeries)
// PATCH  /events/{id}[?occurrence=D&span=this|future|all]
// DELETE /events/{id}[?occurrence=D&span=this|future|all]

import { randomUUID } from "node:crypto";
import { and, asc, eq, gte, isNotNull, isNull, lte, or } from "drizzle-orm";
import { z } from "zod";
import type { Db } from "@/lib/db";
import { apptSearches, calEvents } from "@/lib/db/schema";
import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, readBody } from "@/lib/api/http";
import { addDays, diffDays, isValidDate } from "./dates";
import { expandRule, isRuleOccurrence, normalizeRrule, parseRrule, type Rule, withEnd } from "./rrule";
import { type Range, rangeFromQuery } from "./vacation";

export type EventRow = typeof calEvents.$inferSelect;
export type EventSource = "manual" | "appointment" | "apple";
/** Which occurrences a change of a series is about. */
export type Span = "this" | "future" | "all";

const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const blank = (max: number) => z.string().trim().max(max).optional().default("");
/** Ranges of GET /events (and the calendar's): at most 3 years. */
export const MAX_EVENT_RANGE_DAYS = 3 * 366;
/** Occurrences of one series in one answer at most. */
const MAX_OCCURRENCES = 2000;
const MAX_EXDATES = 1000;
const MAX_OVERRIDES = 1000;

/** The fields of an event or of one occurrence. `end` needs a `start` and, on a one-day event,
 *  must not be before it; `url` only http(s). */
const fieldsSchema = z
  .object({
    date: z.string().refine(isValidDate, "date must be YYYY-MM-DD"),
    endDate: z.string().refine(isValidDate, "endDate must be YYYY-MM-DD").nullish(),
    start: z.string().regex(TIME_RE, "start must be HH:MM").nullish(),
    end: z.string().regex(TIME_RE, "end must be HH:MM").nullish(),
    title: z.string().trim().min(1, "title is required").max(200),
    location: blank(300),
    person: blank(80),
    note: blank(1000),
    url: z
      .string()
      .trim()
      .max(2000)
      .refine((u) => u === "" || /^https?:\/\//i.test(u), "url must start with http:// or https://")
      .optional()
      .default(""),
  })
  .refine((e) => !e.endDate || e.endDate >= e.date, { message: "endDate must not be before date", path: ["endDate"] })
  .refine((e) => !e.end || (!!e.start && ((e.endDate ?? e.date) > e.date || e.end >= e.start)), {
    message: "end must be after start",
    path: ["end"],
  });

/** What an event is made of (POST /events, the booking dialog, the assistant). */
export interface EventInput {
  date: string;
  endDate?: string | null;
  start?: string | null;
  end?: string | null;
  title: string;
  location?: string;
  person?: string;
  note?: string;
  url?: string;
  /** RFC 5545 RRULE value without "RRULE:"; null: doesn't repeat. */
  rrule?: string | null;
  exdates?: string[];
  overrides?: OverrideInput[];
}

export interface OverrideInput {
  occurrence: string;
  date: string;
  endDate?: string | null;
  start?: string | null;
  end?: string | null;
  title: string;
  location?: string;
  person?: string;
  note?: string;
  url?: string;
}

/** An event's or an occurrence's own fields, as stored. */
interface Fields {
  day: string;
  endDay: string;
  start: string | null;
  end: string | null;
  title: string;
  location: string;
  person: string;
  note: string;
  url: string;
}

function cleanFields(raw: unknown): Fields {
  const e = fieldsSchema.parse(raw);
  return {
    day: e.date,
    endDay: e.endDate ?? e.date,
    start: e.start ?? null,
    end: e.start ? (e.end ?? null) : null,
    title: e.title,
    location: e.location,
    person: e.person,
    note: e.note,
    url: e.url,
  };
}

/** Throws (a ZodError) unless `raw` holds fields of an event POST /events accepts (date,
 *  endDate?, start?, end?, title, location?, person?, note?, url?): the assistant's
 *  suggestions (suggest_items) check theirs with it. */
export function checkEventFields(raw: unknown): void {
  cleanFields(raw);
}

const fieldsOf = (r: EventRow): Fields => ({
  day: r.day,
  endDay: r.endDay,
  start: r.start,
  end: r.end,
  title: r.title,
  location: r.location,
  person: r.person,
  note: r.note,
  url: r.url,
});

const shifted = (f: Fields, days: number): Fields =>
  days ? { ...f, day: addDays(f.day, days), endDay: addDays(f.endDay, days) } : f;

/** The fields a PATCH may change (besides rrule, exdates, overrides). */
const EDITABLE = ["date", "endDate", "start", "end", "title", "location", "person", "note", "url"] as const;

/** `base` with the body's fields: `start`/`end` null clear them, clearing the start clears the
 *  kept end too; a new `date` moves the end day along unless the body has `endDate`. */
function mergeFields(base: Fields, body: Record<string, unknown>): Fields {
  const merged: Record<string, unknown> = {
    date: base.day,
    endDate: base.endDay,
    start: base.start,
    end: base.end,
    title: base.title,
    location: base.location,
    person: base.person,
    note: base.note,
    url: base.url,
  };
  for (const key of EDITABLE) if (key in body) merged[key] = body[key];
  if ("date" in body && !("endDate" in body) && isValidDate(body.date)) {
    merged.endDate = addDays(base.endDay, diffDays(base.day, body.date));
  }
  // An all-day event has no end: clearing the start clears the kept end too.
  if (!merged.start && !("end" in body)) merged.end = null;
  return cleanFields(merged);
}

function cleanRrule(v: unknown): string | null {
  return v === undefined || v === null ? null : normalizeRrule(v);
}

function cleanExdates(v: unknown): string[] {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v)) throw new HttpError(400, "exdates must be an array of dates");
  if (v.length > MAX_EXDATES) throw new HttpError(400, `Too many exdates (max. ${MAX_EXDATES})`);
  for (const d of v) if (!isValidDate(d)) throw new HttpError(400, `exdates: invalid date "${d}" (use YYYY-MM-DD)`);
  return [...new Set(v as string[])].sort();
}

interface Override {
  occurrence: string;
  fields: Fields;
}

function cleanOverrides(v: unknown): Override[] {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v)) throw new HttpError(400, "overrides must be an array");
  if (v.length > MAX_OVERRIDES) throw new HttpError(400, `Too many overrides (max. ${MAX_OVERRIDES})`);
  const seen = new Set<string>();
  return v.map((raw) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new HttpError(400, "Each override must be an object");
    const o = raw as Record<string, unknown>;
    if (!isValidDate(o.occurrence)) throw new HttpError(400, "An override's occurrence must be YYYY-MM-DD");
    if (seen.has(o.occurrence)) throw new HttpError(400, `Two overrides of ${o.occurrence}`);
    seen.add(o.occurrence);
    return { occurrence: o.occurrence, fields: cleanFields(o) };
  });
}

// ------------------------------------------------------------------ reading

/** A series (or a single event) with what belongs to it. */
export interface Series {
  row: EventRow;
  /** Null: doesn't repeat. */
  rule: Rule | null;
  exdates: string[];
  /** Sorted by occurrence. */
  overrides: EventRow[];
}

function parseExdatesColumn(s: string): string[] {
  try {
    const v = JSON.parse(s);
    return Array.isArray(v) ? v.filter(isValidDate) : [];
  } catch {
    return [];
  }
}

function seriesOf(row: EventRow, overrides: EventRow[]): Series {
  return {
    row,
    rule: row.rrule ? parseRrule(row.rrule) : null,
    exdates: row.rrule ? parseExdatesColumn(row.exdates) : [],
    overrides: row.rrule ? overrides.sort((a, b) => a.occurrence!.localeCompare(b.occurrence!)) : [],
  };
}

/** The family's series and single events; with a range only those that may touch it (every
 *  repeating one, single ones overlapping it). */
export function loadSeries(db: Db, familyId: string, range?: { from: string; to: string }): Series[] {
  const rows = db
    .select()
    .from(calEvents)
    .where(
      and(
        eq(calEvents.familyId, familyId),
        isNull(calEvents.seriesId),
        range ? or(isNotNull(calEvents.rrule), and(lte(calEvents.day, range.to), gte(calEvents.endDay, range.from))) : undefined,
      ),
    )
    .orderBy(asc(calEvents.day), asc(calEvents.start), asc(calEvents.createdAt))
    .all();
  const bySeries = new Map<string, EventRow[]>();
  if (rows.some((r) => r.rrule)) {
    const overrides = db
      .select()
      .from(calEvents)
      .where(and(eq(calEvents.familyId, familyId), isNotNull(calEvents.seriesId)))
      .all();
    for (const o of overrides) bySeries.set(o.seriesId!, [...(bySeries.get(o.seriesId!) ?? []), o]);
  }
  return rows.map((r) => seriesOf(r, bySeries.get(r.id) ?? []));
}

/** One of the family's series or single events (never an override's row), or null. */
export function getSeries(db: Db, familyId: string, id: string): Series | null {
  const row = db
    .select()
    .from(calEvents)
    .where(and(eq(calEvents.familyId, familyId), eq(calEvents.id, id), isNull(calEvents.seriesId)))
    .get();
  if (!row) return null;
  const overrides = row.rrule
    ? db
        .select()
        .from(calEvents)
        .where(and(eq(calEvents.familyId, familyId), eq(calEvents.seriesId, id)))
        .all()
    : [];
  return seriesOf(row, overrides);
}

/** An occurrence as calendars show it. `id` is always the series' (or single event's) id;
 *  `occurrence` (the original date) is set exactly for events that repeat. */
export interface PublicEvent {
  id: string;
  occurrence: string | null;
  date: string;
  endDate: string;
  start: string | null;
  end: string | null;
  title: string;
  location: string;
  person: string;
  note: string;
  url: string;
  source: EventSource;
  /** The appointment search it came from (source "appointment"). */
  searchId: string | null;
  /** The Apple Calendar event it was imported from (source "apple"). */
  externalId: string | null;
  rrule: string | null;
}

const sourceOf = (r: EventRow): EventSource => (r.source === "appointment" || r.source === "apple" ? r.source : "manual");

function occurrenceEvent(series: EventRow, occurrence: string | null, f: Fields): PublicEvent {
  return {
    id: series.id,
    occurrence,
    date: f.day,
    endDate: f.endDay,
    start: f.start,
    end: f.end,
    title: f.title,
    location: f.location,
    person: f.person,
    note: f.note,
    url: f.url,
    source: sourceOf(series),
    searchId: series.source === "appointment" ? series.sourceId : null,
    externalId: series.source === "apple" ? series.sourceItem : null,
    rrule: series.rrule,
  };
}

/** A series' (or single event's) row as its first occurrence. */
export function publicEvent(row: EventRow): PublicEvent {
  return occurrenceEvent(row, row.rrule ? row.day : null, fieldsOf(row));
}

/** Whether `date` is an occurrence of the series (produced by its rule, not taken out). */
export function isOccurrence(s: Series, date: string): boolean {
  if (!s.rule) return date === s.row.day;
  return !s.exdates.includes(date) && isRuleOccurrence(s.rule, s.row.day, date);
}

/** The series' occurrences overlapping `from`..`to` (an override where there is one). */
export function occurrencesOf(s: Series, from: string, to: string, limit = MAX_OCCURRENCES): PublicEvent[] {
  const { row, rule } = s;
  if (!rule) return row.day <= to && row.endDay >= from ? [publicEvent(row)] : [];
  const span = diffDays(row.day, row.endDay);
  const exdates = new Set(s.exdates);
  const overridden = new Map(s.overrides.map((o) => [o.occurrence!, o]));
  const out: PublicEvent[] = [];
  const own = fieldsOf(row);
  for (const d of expandRule(rule, row.day, addDays(from, -span), to, limit)) {
    if (exdates.has(d) || overridden.has(d)) continue;
    out.push(occurrenceEvent(row, d, shifted(own, diffDays(row.day, d))));
  }
  for (const o of s.overrides) {
    if (o.day > to || o.endDay < from) continue;
    if (exdates.has(o.occurrence!) || !isRuleOccurrence(rule, row.day, o.occurrence!)) continue;
    out.push(occurrenceEvent(row, o.occurrence, fieldsOf(o)));
  }
  return out;
}

/** Sorts occurrences: by date, all-day first, by start, then as the series were created. */
export function sortOccurrences(events: PublicEvent[], series: Series[]): PublicEvent[] {
  const created = new Map(series.map((s) => [s.row.id, s.row.createdAt.getTime()]));
  return events.sort(
    (a, b) =>
      a.date.localeCompare(b.date) ||
      (a.start === null ? 0 : 1) - (b.start === null ? 0 : 1) ||
      (a.start ?? "").localeCompare(b.start ?? "") ||
      (created.get(a.id) ?? 0) - (created.get(b.id) ?? 0) ||
      a.id.localeCompare(b.id) ||
      (a.occurrence ?? "").localeCompare(b.occurrence ?? ""),
  );
}

/** Every occurrence overlapping the range (`date <= to && endDate >= from`), sorted. */
export function listOccurrences(db: Db, familyId: string, { from, to }: { from: string; to: string }): PublicEvent[] {
  const series = loadSeries(db, familyId, { from, to });
  return sortOccurrences(
    series.flatMap((s) => occurrencesOf(s, from, to)),
    series,
  );
}

/** day -> its events, as GET /families/{id} hands them to the calendar: each occurrence under
 *  every day of the range it covers. */
export function eventsByDay(events: PublicEvent[], { from, to }: { from: string; to: string }): Record<string, PublicEvent[]> {
  const out: Record<string, PublicEvent[]> = {};
  for (const e of events) {
    const last = e.endDate < to ? e.endDate : to;
    for (let d = e.date > from ? e.date : from; d <= last; d = addDays(d, 1)) (out[d] ??= []).push(e);
  }
  return out;
}

/** The range of the calendar's events: the given one, a missing end the other end's year (the
 *  current year without either); 400 if it is longer than 3 years. */
export function eventRange(range: Range, now: Date = new Date()): { from: string; to: string } {
  const from = range.from ?? `${(range.to ?? now.toISOString()).slice(0, 4)}-01-01`;
  const to = range.to ?? `${from.slice(0, 4)}-12-31`;
  if (from > to) throw new HttpError(400, "from must not be after to");
  if (diffDays(from, to) > MAX_EVENT_RANGE_DAYS) throw new HttpError(400, "The range is too long (max. 3 years)");
  return { from, to };
}

/** A whole series as editors and the Apple sync see it. */
export interface EventSeries {
  id: string;
  date: string;
  endDate: string;
  start: string | null;
  end: string | null;
  title: string;
  location: string;
  person: string;
  note: string;
  url: string;
  source: EventSource;
  searchId: string | null;
  externalId: string | null;
  rrule: string | null;
  exdates: string[];
  overrides: {
    occurrence: string;
    date: string;
    endDate: string;
    start: string | null;
    end: string | null;
    title: string;
    location: string;
    person: string;
    note: string;
    url: string;
  }[];
}

export function seriesJson(s: Series): EventSeries {
  const { occurrence: _, ...head } = publicEvent(s.row);
  return {
    ...head,
    exdates: s.exdates,
    overrides: s.overrides.map((o) => ({
      occurrence: o.occurrence!,
      date: o.day,
      endDate: o.endDay,
      start: o.start,
      end: o.end,
      title: o.title,
      location: o.location,
      person: o.person,
      note: o.note,
      url: o.url,
    })),
  };
}

/** The series as a POST /events / PATCH body that puts it back as it is (the assistant's undo). */
export function seriesBody(s: Series): Record<string, unknown> {
  const e = seriesJson(s);
  return {
    date: e.date,
    endDate: e.endDate,
    start: e.start,
    end: e.end,
    title: e.title,
    location: e.location,
    person: e.person,
    note: e.note,
    url: e.url,
    rrule: e.rrule,
    exdates: e.exdates,
    overrides: e.overrides,
  };
}

// ------------------------------------------------------------------ writing

interface Meta {
  source?: EventSource;
  sourceId?: string | null;
  sourceItem?: string | null;
  createdById?: string | null;
}

/** Stores the series `id` as given: its row (inserted with `insert`, else updated), its
 *  exdates and its overrides (all replaced; those of dates that aren't occurrences dropped).
 *  A single event keeps neither. */
function saveSeries(
  db: Db,
  familyId: string,
  id: string,
  fields: Fields,
  rrule: string | null,
  exdates: string[],
  overrides: Override[],
  now: Date,
  insert?: Meta,
): Series {
  const rule = rrule ? parseRrule(rrule) : null;
  const ex = rule ? [...new Set(exdates)].sort() : [];
  const kept = rule
    ? overrides.filter((o) => !ex.includes(o.occurrence) && isRuleOccurrence(rule, fields.day, o.occurrence))
    : [];
  const values = { ...fields, rrule, exdates: JSON.stringify(ex) };
  return db.transaction((tx) => {
    if (insert) {
      tx.insert(calEvents)
        .values({
          id,
          familyId,
          ...values,
          source: insert.source ?? "manual",
          sourceId: insert.sourceId ?? null,
          sourceItem: insert.sourceItem ?? null,
          createdById: insert.createdById ?? null,
          createdAt: now,
        })
        .run();
    } else {
      tx.update(calEvents)
        .set(values)
        .where(and(eq(calEvents.familyId, familyId), eq(calEvents.id, id)))
        .run();
      tx.delete(calEvents).where(and(eq(calEvents.familyId, familyId), eq(calEvents.seriesId, id))).run();
    }
    for (const o of kept) {
      tx.insert(calEvents)
        .values({
          id: randomUUID(),
          familyId,
          ...o.fields,
          seriesId: id,
          occurrence: o.occurrence,
          createdAt: now,
        })
        .run();
    }
    return getSeries(tx as unknown as Db, familyId, id)!;
  });
}

const overridesOf = (s: Series): Override[] => s.overrides.map((o) => ({ occurrence: o.occurrence!, fields: fieldsOf(o) }));

/** Adds an event (a series with `rrule`); returns its row. */
export function createEvent(db: Db, familyId: string, input: EventInput, meta: Meta, now: Date): EventRow {
  return createSeries(db, familyId, input as unknown as Record<string, unknown>, meta, now).row;
}

export function createSeries(db: Db, familyId: string, body: Record<string, unknown>, meta: Meta, now: Date): Series {
  const fields = cleanFields(body);
  const rrule = cleanRrule(body.rrule);
  return saveSeries(db, familyId, randomUUID(), fields, rrule, cleanExdates(body.exdates), cleanOverrides(body.overrides), now, meta);
}

/** Which occurrences a request is about: `?occurrence=D&span=this|future|all`. */
export interface Target {
  occurrence: string | null;
  span: Span;
}

export function cleanTarget(occurrence: unknown, span: unknown): Target {
  if (span !== undefined && span !== null && span !== "this" && span !== "future" && span !== "all") {
    throw new HttpError(400, "span must be this, future or all");
  }
  const s = (span ?? (occurrence ? "this" : "all")) as Span;
  if (s === "all") return { occurrence: null, span: "all" };
  if (occurrence === undefined || occurrence === null || occurrence === "") {
    throw new HttpError(400, `span ${s} needs an occurrence`);
  }
  if (!isValidDate(occurrence)) throw new HttpError(400, "occurrence must be YYYY-MM-DD");
  return { occurrence, span: s };
}

function targetFromQuery(url: URL): Target {
  return cleanTarget(url.searchParams.get("occurrence"), url.searchParams.get("span"));
}

function requireSeries(db: Db, familyId: string, id: string): Series {
  const s = getSeries(db, familyId, id);
  if (!s) throw new HttpError(404, "Event not found");
  return s;
}

/** Checks that `target` names an occurrence of the series: 400 for a single event, 404 for a
 *  date that isn't one. */
function requireOccurrence(s: Series, date: string): void {
  if (!s.rule) throw new HttpError(400, "This event doesn't repeat: change it without an occurrence");
  if (!isOccurrence(s, date)) throw new HttpError(404, `${date} is not an occurrence of this event`);
}

/** The occurrence `date` as it is now: its override, else the series' fields moved there. */
function occurrenceFields(s: Series, date: string): Fields {
  const o = s.overrides.find((x) => x.occurrence === date);
  return o ? fieldsOf(o) : shifted(fieldsOf(s.row), diffDays(s.row.day, date));
}

/** What a PATCH did: the series it answers with, and whether that one is new (a split). */
export interface UpdateResult {
  series: Series;
  created: boolean;
}

/** PATCH /events/{id}[?occurrence=D&span=…]: the whole series ("all"), one occurrence ("this":
 *  its override) or "this and following" ("future": the series ends before D, a new one
 *  starts with D). */
export function updateSeries(db: Db, familyId: string, id: string, body: Record<string, unknown>, target: Target, now: Date, createdById?: string | null): UpdateResult {
  const s = requireSeries(db, familyId, id);
  if (target.span !== "all") requireOccurrence(s, target.occurrence!);
  if (target.span === "this") {
    const date = target.occurrence!;
    const fields = mergeFields(occurrenceFields(s, date), body);
    const overrides = [...overridesOf(s).filter((o) => o.occurrence !== date), { occurrence: date, fields }];
    return { series: saveSeries(db, familyId, id, fieldsOf(s.row), s.row.rrule, s.exdates, overrides, now), created: false };
  }
  if (target.span === "future" && target.occurrence !== s.row.day) return splitSeries(db, familyId, s, target.occurrence!, body, now, createdById);

  // All occurrences (also "future" from the first one).
  const fields = mergeFields(fieldsOf(s.row), body);
  const shift = diffDays(s.row.day, fields.day);
  const rrule = "rrule" in body ? cleanRrule(body.rrule) : s.row.rrule;
  const exdates = "exdates" in body ? cleanExdates(body.exdates) : s.exdates.map((d) => addDays(d, shift));
  const overrides =
    "overrides" in body
      ? cleanOverrides(body.overrides)
      : overridesOf(s).map((o) => ({ occurrence: addDays(o.occurrence, shift), fields: shifted(o.fields, shift) }));
  return { series: saveSeries(db, familyId, id, fields, rrule, exdates, overrides, now), created: false };
}

/** "This and following" from occurrence `date` (not the first): the series ends the day before,
 *  a new one starts with the occurrence as it is now changed by `body`, with the same rule
 *  (what is left of a COUNT) unless `body` has one, and takes over the exdates and overrides
 *  from `date` on (moved along when the first day moved). */
function splitSeries(db: Db, familyId: string, s: Series, date: string, body: Record<string, unknown>, now: Date, createdById?: string | null): UpdateResult {
  const rule = s.rule!;
  const fields = mergeFields(occurrenceFields(s, date), body);
  const shift = diffDays(date, fields.day);
  let rrule: string | null;
  if ("rrule" in body) rrule = cleanRrule(body.rrule);
  else if (rule.count !== null) {
    const before = expandRule(rule, s.row.day, s.row.day, addDays(date, -1), rule.count).length;
    rrule = withEnd(s.row.rrule!, { count: rule.count - before });
  } else rrule = s.row.rrule;
  const exdates =
    "exdates" in body ? cleanExdates(body.exdates) : s.exdates.filter((d) => d > date).map((d) => addDays(d, shift));
  const overrides =
    "overrides" in body
      ? cleanOverrides(body.overrides)
      : overridesOf(s)
          .filter((o) => o.occurrence > date)
          .map((o) => ({ occurrence: addDays(o.occurrence, shift), fields: shifted(o.fields, shift) }));
  return db.transaction((tx) => {
    endSeriesBefore(tx as unknown as Db, familyId, s, date, now);
    const created = saveSeries(tx as unknown as Db, familyId, randomUUID(), fields, rrule, exdates, overrides, now, { createdById });
    return { series: created, created: true };
  });
}

/** Ends the series the day before `date`: UNTIL (a COUNT becomes it), and drops the exdates
 *  and overrides from `date` on. */
function endSeriesBefore(db: Db, familyId: string, s: Series, date: string, now: Date): Series {
  const rrule = withEnd(s.row.rrule!, { until: addDays(date, -1) });
  return saveSeries(
    db,
    familyId,
    s.row.id,
    fieldsOf(s.row),
    rrule,
    s.exdates.filter((d) => d < date),
    overridesOf(s).filter((o) => o.occurrence < date),
    now,
  );
}

/** DELETE /events/{id}[?occurrence=D&span=…]: the series ("all", or "future" from the first
 *  occurrence) → null; one occurrence (an exdate) or this and the following ones → the series. */
export function deleteSeries(db: Db, familyId: string, id: string, target: Target, now: Date): Series | null {
  const s = requireSeries(db, familyId, id);
  if (target.span !== "all") requireOccurrence(s, target.occurrence!);
  const date = target.occurrence!;
  if (target.span === "this") {
    return saveSeries(
      db,
      familyId,
      id,
      fieldsOf(s.row),
      s.row.rrule,
      [...s.exdates, date],
      overridesOf(s).filter((o) => o.occurrence !== date),
      now,
    );
  }
  if (target.span === "future" && date !== s.row.day) return endSeriesBefore(db, familyId, s, date, now);
  db.delete(calEvents).where(and(eq(calEvents.familyId, familyId), eq(calEvents.id, id))).run();
  return null;
}

/** Deletes one of the family's events (a series with its overrides); false if it has no such
 *  event. */
export function deleteEvent(db: Db, familyId: string, id: string): boolean {
  const res = db
    .delete(calEvents)
    .where(and(eq(calEvents.familyId, familyId), eq(calEvents.id, id), isNull(calEvents.seriesId)))
    .run();
  return res.changes > 0;
}

/** Events of booked appointments ending `from` or later (all if omitted), by day. */
export function listBookedAppointments(db: Db, familyId: string, from?: string): EventRow[] {
  return db
    .select()
    .from(calEvents)
    .where(
      and(
        eq(calEvents.familyId, familyId),
        isNull(calEvents.seriesId),
        eq(calEvents.source, "appointment"),
        from ? gte(calEvents.endDay, from) : undefined,
      ),
    )
    .orderBy(asc(calEvents.day), asc(calEvents.start), asc(calEvents.createdAt))
    .all();
}

/** The booking of a slot (a result of a search), if it was marked as booked. */
export function findBooking(db: Db, familyId: string, searchId: string, resultId: number): EventRow | null {
  return (
    db
      .select()
      .from(calEvents)
      .where(
        and(
          eq(calEvents.familyId, familyId),
          isNull(calEvents.seriesId),
          eq(calEvents.source, "appointment"),
          eq(calEvents.sourceId, searchId),
          eq(calEvents.sourceItem, String(resultId)),
        ),
      )
      .get() ?? null
  );
}

/** The family's event imported from the Apple Calendar event `externalId`, if any. */
export function findExternalEvent(db: Db, familyId: string, externalId: string): EventRow | null {
  return (
    db
      .select()
      .from(calEvents)
      .where(
        and(
          eq(calEvents.familyId, familyId),
          isNull(calEvents.seriesId),
          eq(calEvents.source, "apple"),
          eq(calEvents.sourceItem, externalId),
        ),
      )
      .get() ?? null
  );
}

/** `externalId` of POST /events: an Apple Calendar event's identifier. */
const externalIdSchema = z.string().trim().min(1, "externalId must not be empty").max(500);

// ------------------------------------------------------------------ REST

/** Routes /families/{id}/events[/{eventId}]; null for anything else. */
export function handleEvents(ctx: Ctx): Promise<Response> | null {
  if (ctx.rest[0] !== "events" || ctx.rest.length > 2) return null;
  const id = ctx.rest[1];
  if (id === undefined && ctx.method === "GET") return listRoute(ctx);
  if (id === undefined && ctx.method === "POST") return createRoute(ctx);
  if (id !== undefined && ctx.method === "GET") return getRoute(ctx, id);
  if (id !== undefined && ctx.method === "PATCH") return updateRoute(ctx, id);
  if (id !== undefined && ctx.method === "DELETE") return deleteRoute(ctx, id);
  return Promise.reject(new HttpError(405, "Method not allowed"));
}

/** The range of GET /events: ?year= or ?from=&to=, both ends, at most 3 years. */
export function requiredRange(url: URL): { from: string; to: string } {
  const range = rangeFromQuery(url);
  if (!range.from || !range.to) throw new HttpError(400, "Give from and to (or year)");
  return eventRange(range);
}

/** GET /events?year= | ?from=&to= → {events: [PublicEvent]}; ?raw=1 → {events: [EventSeries]} */
async function listRoute({ db, url, load }: Ctx): Promise<Response> {
  const { family } = await load("view");
  if (url.searchParams.get("raw") === "1") return json({ events: loadSeries(db, family.id).map(seriesJson) });
  const range = requiredRange(url);
  return json({ events: listOccurrences(db, family.id, range) });
}

/** GET /events/{id} → EventSeries */
async function getRoute({ db, load }: Ctx, id: string): Promise<Response> {
  const { family } = await load("view");
  return json(seriesJson(requireSeries(db, family.id, id)));
}

/** POST /events {date, endDate?, start?, end?, title, location?, person?, note?, url?, rrule?,
 *  exdates?, overrides?} → 201 EventSeries. With `searchId` and `resultId` (a booked slot put
 *  back, e.g. the assistant's undo) it is that search's booking again; the search must be the
 *  family's. With `externalId` (an Apple Calendar event the app imports) it is saved with
 *  source "apple"; when the family already has that one, it is answered unchanged with 200
 *  instead (two devices may import it). */
async function createRoute({ db, req, load, now, principal }: Ctx): Promise<Response> {
  const { family } = await load("edit");
  const body = await readBody(req);
  let meta: Meta = {};
  if (body.externalId !== undefined && body.externalId !== null) {
    if ((body.searchId ?? null) !== null || (body.resultId ?? null) !== null) {
      throw new HttpError(400, "externalId can't be combined with searchId / resultId");
    }
    const externalId = externalIdSchema.parse(body.externalId);
    // Check and insert without awaiting in between: no other request runs in the meantime.
    const existing = findExternalEvent(db, family.id, externalId);
    if (existing) return json(seriesJson(requireSeries(db, family.id, existing.id)), 200);
    const s = createSeries(db, family.id, body, { source: "apple", sourceItem: externalId, createdById: principal?.id }, now);
    return json(seriesJson(s), 201);
  }
  if (typeof body.searchId === "string" && body.resultId !== undefined && body.resultId !== null) {
    const search = db
      .select({ id: apptSearches.id })
      .from(apptSearches)
      .where(and(eq(apptSearches.familyId, family.id), eq(apptSearches.id, body.searchId)))
      .get();
    if (!search) throw new HttpError(404, "Search not found");
    meta = { source: "appointment", sourceId: search.id, sourceItem: String(body.resultId) };
  }
  const s = createSeries(db, family.id, body, { ...meta, createdById: principal?.id }, now);
  return json(seriesJson(s), 201);
}

/** PATCH /events/{id}[?occurrence=D&span=this|future|all] → EventSeries (the new one, 201,
 *  when "future" split the series). The source stays. */
async function updateRoute({ db, req, url, load, now, principal }: Ctx, id: string): Promise<Response> {
  const target = targetFromQuery(url);
  const { family } = await load("edit");
  const body = await readBody(req);
  const { series, created } = updateSeries(db, family.id, id, body, target, now, principal?.id);
  return json(seriesJson(series), created ? 201 : 200);
}

/** DELETE /events/{id}[?occurrence=D&span=this|future|all] → {deleted: id} or EventSeries */
async function deleteRoute({ db, url, load, now }: Ctx, id: string): Promise<Response> {
  const target = targetFromQuery(url);
  const { family } = await load("edit");
  const s = deleteSeries(db, family.id, id, target, now);
  return json(s ? seriesJson(s) : { deleted: id });
}
