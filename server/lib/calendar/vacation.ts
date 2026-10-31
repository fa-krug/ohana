// The calendar: entry types per year, day entries, day notes and the iCalendar feed (ported
// from family-planner's _shared/vacation.ts; the routes keep its paths and JSON shapes).

import type { Ctx } from "@/lib/api/family-api";
import { cleanName, cleanYear, CORS, currentYear, HttpError, json, objectOf, readBody, slug } from "@/lib/api/http";
import { dateRange, isValidDate, isWeekend } from "./dates";
import { buildIcs, type Lang } from "./ics";
import { familyNames } from "@/lib/families/people";
import { listEvents } from "./events";
import { type CalendarStore as Store, type EntryRow, type NoteRow, type Role, ROLES, type TypeRow } from "./store";

export const PRESET_TYPES: { id: string; name: string; color: string; role: Role }[] = [
  { id: "holiday", name: "Holiday", color: "#f59e0b", role: "day_off" },
  { id: "vacation", name: "Vacation", color: "#22c55e", role: "covers" },
  { id: "sick", name: "Sick", color: "#ef4444", role: "none" },
];

/** Localized preset names by type id; ids, colors and roles stay the same. */
const PRESET_NAMES: Record<Lang, Record<string, string>> = {
  en: Object.fromEntries(PRESET_TYPES.map((t) => [t.id, t.name])),
  de: { holiday: "Feiertag", vacation: "Urlaub", sick: "Krank" },
};

export const MAX_TYPES = 50; // per year
const MAX_DAYS_PER_REQUEST = 4000;
const MAX_RANGE_DAYS = 3 * 366;
const MAX_ICON = 16; // UTF-16 code units: enough for flags and ZWJ emoji
const MAX_COMMENT = 500;
const MAX_IMPORT_YEARS = 50;
const MAX_IMPORT_DAYS = 20000; // days with entries, and days with notes
const COLOR_RE = /^#[0-9a-fA-F]{6}$/;
// Type ids come from slug() and uniqueId(); imports must look the same.
const TYPE_ID_RE = /^[a-z0-9][a-z0-9-]{0,47}$/;

export function cleanColor(v: unknown): string {
  if (typeof v !== "string" || !COLOR_RE.test(v)) {
    throw new HttpError(400, "color must look like #22c55e");
  }
  return v.toLowerCase();
}

export function cleanRole(v: unknown): Role {
  if (v === undefined) return "none";
  if (!ROLES.includes(v as Role)) {
    throw new HttpError(400, `role must be one of ${ROLES.join(", ")}`);
  }
  return v as Role;
}

/** Year a types request is about: `?year=`, else the body's "year", else the current year. */
function typesYear(url: URL, body: Record<string, unknown> = {}, now?: Date): number {
  const v = url.searchParams.get("year") ?? body.year;
  return v === undefined ? currentYear(now) : cleanYear(v);
}

export function uniqueId(base: string, taken: Set<string>): string {
  let id = base;
  for (let i = 2; taken.has(id); i++) id = `${base}-${i}`;
  return id;
}

/** The types of a new family: the body's `types` if given, else the localized presets. */
export function newFamilyTypes(raw: unknown, lang: Lang) {
  if (raw === undefined) return PRESET_TYPES.map((t) => ({ ...t, name: PRESET_NAMES[lang][t.id] }));
  if (!Array.isArray(raw)) throw new HttpError(400, "types must be an array");
  const taken = new Set<string>();
  return raw.slice(0, MAX_TYPES).map((t: Record<string, unknown>) => {
    const name = cleanName(t?.name);
    const id = uniqueId(slug(name), taken);
    taken.add(id);
    return { id, name, color: cleanColor(t.color), role: cleanRole(t.role), away: cleanAway(t.away) };
  });
}

/** Resolves a type reference given by id or (case-insensitive) name among a year's types. */
export function resolveType(types: TypeRow[], ref: unknown, year: number): TypeRow {
  if (typeof ref !== "string") throw new HttpError(400, "type must be a string");
  const t =
    types.find((t) => t.year === year && t.id === ref) ??
    types.find((t) => t.year === year && t.name.toLowerCase() === ref.trim().toLowerCase());
  if (!t) throw new HttpError(404, `Unknown entry type "${ref}" in ${year}`);
  return t;
}

const yearOf = (day: string) => Number(day.slice(0, 4));

export type Range = { from?: string; to?: string };

/** Range from ?year= or ?from=&to= query parameters. */
export function rangeFromQuery(url: URL): Range {
  const year = url.searchParams.get("year");
  if (year) {
    if (!/^\d{4}$/.test(year)) throw new HttpError(400, "year must be YYYY");
    return { from: `${year}-01-01`, to: `${year}-12-31` };
  }
  const from = url.searchParams.get("from") ?? undefined;
  const to = url.searchParams.get("to") ?? undefined;
  for (const d of [from, to]) {
    if (d !== undefined && !isValidDate(d)) throw new HttpError(400, "from/to must be YYYY-MM-DD");
  }
  return { from, to };
}

export function publicType(t: TypeRow) {
  return {
    id: t.id,
    year: t.year,
    name: t.name,
    color: t.color,
    role: t.role,
    position: t.position,
    away: t.away ?? false,
  };
}

/** The optional "away" flag of a type (Ohana's addition; family-planner's files have none). */
export function cleanAway(v: unknown): boolean {
  if (v === undefined || v === null) return false;
  if (typeof v !== "boolean") throw new HttpError(400, "away must be true or false");
  return v;
}

export type VacationData = [TypeRow[], EntryRow[], NoteRow[]];

/** All types, and the entries and notes in the range. */
export function listVacation(store: Store, familyId: string, { from, to }: Range) {
  return Promise.all([
    store.listTypes(familyId),
    store.listEntries(familyId, from, to),
    store.listNotes(familyId, from, to),
  ]);
}

/**
 * The calendar as the app loads it. `types` are all types of the family; the state holds
 * those of the range's years, plus `typeYears`: every year that has types of its own.
 */
export function vacationState(range: Range, [types, rows, notes]: VacationData) {
  return {
    types: types
      .filter((t) => !(range.from && t.year < yearOf(range.from)) && !(range.to && t.year > yearOf(range.to)))
      .map(publicType),
    typeYears: [...new Set(types.map((t) => t.year))].sort((a, b) => a - b),
    entries: groupEntries(rows),
    notes: notesMap(notes),
  };
}

export function groupEntries(rows: EntryRow[]): Record<string, string[]> {
  const entries: Record<string, string[]> = {};
  for (const r of rows) (entries[r.day] ??= []).push(r.type_id);
  return entries;
}

export function notesMap(rows: NoteRow[]): Record<string, { icon: string; comment: string }> {
  return Object.fromEntries(rows.map((n) => [n.day, { icon: n.icon, comment: n.comment }]));
}

function dayMap(v: unknown, field: string): [string, unknown][] {
  if (v === undefined) return [];
  const list = Object.entries(objectOf(v, field));
  if (list.length > MAX_IMPORT_DAYS) throw new HttpError(400, `Too many days in ${field}`);
  for (const [day] of list) {
    if (!isValidDate(day)) throw new HttpError(400, `Invalid date "${day}" in ${field}`);
  }
  return list;
}

/** Validates the calendar part of an export file (types, entries, notes) for importing. */
export function parseVacationImport(body: Record<string, unknown>) {
  if (!Array.isArray(body.types)) throw new HttpError(400, "types must be an array");
  const types: Omit<TypeRow, "family_id">[] = [];
  const keys = new Set<string>();
  const perYear = new Map<number, number>();
  for (const [i, raw] of body.types.entries()) {
    const t = objectOf(raw, "Each type");
    const year = cleanYear(t.year, "type year");
    if (typeof t.id !== "string" || !TYPE_ID_RE.test(t.id)) {
      throw new HttpError(400, `Invalid type id "${t.id}"`);
    }
    if (keys.has(`${year}|${t.id}`)) {
      throw new HttpError(400, `Duplicate type "${t.id}" in ${year}`);
    }
    keys.add(`${year}|${t.id}`);
    perYear.set(year, (perYear.get(year) ?? 0) + 1);
    if (perYear.get(year)! > MAX_TYPES) throw new HttpError(400, `Too many entry types in ${year}`);
    types.push({
      year,
      id: t.id,
      name: cleanName(t.name),
      color: cleanColor(t.color),
      role: cleanRole(t.role),
      position: Number.isInteger(t.position) ? (t.position as number) : i,
      away: cleanAway(t.away),
    });
  }
  if (perYear.size > MAX_IMPORT_YEARS) throw new HttpError(400, "Too many years");

  const entries: EntryRow[] = [];
  for (const [day, ids] of dayMap(body.entries, "entries")) {
    if (!Array.isArray(ids)) throw new HttpError(400, `entries of ${day} must be an array`);
    for (const id of new Set(ids)) {
      if (typeof id !== "string" || !keys.has(`${yearOf(day)}|${id}`)) {
        throw new HttpError(400, `Unknown entry type "${id}" in ${yearOf(day)}`);
      }
      entries.push({ day, type_id: id });
    }
  }

  const notes: NoteRow[] = [];
  for (const [day, raw] of dayMap(body.notes, "notes")) {
    const n = objectOf(raw, `The note of ${day}`);
    const icon = cleanNoteText(n.icon, "icon", MAX_ICON);
    const comment = cleanNoteText(n.comment, "comment", MAX_COMMENT);
    if (icon || comment) notes.push({ day, icon, comment });
  }
  return { types, entries, notes };
}

function opObject(raw: unknown): Record<string, unknown> {
  if (!raw || typeof raw !== "object") throw new HttpError(400, "Each op must be an object");
  return raw as Record<string, unknown>;
}

/** Days of an entry or note op: `dates`, `date` and/or `from`/`to`, minus weekends if asked. */
function parseDays(o: Record<string, unknown>): string[] {
  const days = new Set<string>();
  const dates = o.dates ?? (o.date !== undefined ? [o.date] : []);
  if (!Array.isArray(dates)) throw new HttpError(400, "dates must be an array");
  for (const d of dates) {
    if (!isValidDate(d)) throw new HttpError(400, `Invalid date "${d}" (use YYYY-MM-DD)`);
    days.add(d);
  }
  if (o.from !== undefined || o.to !== undefined) {
    const from = o.from ?? o.to;
    const to = o.to ?? o.from;
    if (!isValidDate(from) || !isValidDate(to)) {
      throw new HttpError(400, "from/to must be YYYY-MM-DD");
    }
    const range = dateRange(from, to);
    if (range.length > MAX_RANGE_DAYS) throw new HttpError(400, "Range is too long");
    for (const d of range) days.add(d);
  }
  let list = [...days].sort();
  if (o.skipWeekends === true) list = list.filter((d) => !isWeekend(d));
  if (list.length === 0) throw new HttpError(400, 'Op needs "dates" or "from"/"to"');
  return list;
}

type Op = {
  action: "add" | "remove" | "set" | "clear";
  days: string[];
  /** The days split by year, each with the type ids its references resolve to in that year. */
  byYear: { types: string[]; days: string[] }[];
};

function parseOp(raw: unknown, types: TypeRow[]): Op {
  const o = opObject(raw);
  const action = o.action ?? "add";
  if (!["add", "remove", "set", "clear"].includes(action as string)) {
    throw new HttpError(400, "action must be add, remove, set or clear");
  }

  let refs: unknown[] = [];
  if (o.types !== undefined) {
    if (!Array.isArray(o.types)) throw new HttpError(400, "types must be an array");
    refs = o.types;
  } else if (o.type !== undefined) refs = [o.type];
  if ((action === "add" || action === "remove") && refs.length === 0) {
    throw new HttpError(400, `"${action}" needs "type" or "types"`);
  }
  const days = parseDays(o);
  // Every year has its own types, so the same name may stand for a different id per year.
  const years = new Map<number, string[]>();
  for (const day of days) {
    const list = years.get(yearOf(day)) ?? [];
    list.push(day);
    years.set(yearOf(day), list);
  }
  const byYear = [...years].map(([year, days]) => ({
    types: [...new Set(refs.map((r) => resolveType(types, r, year).id))],
    days,
  }));
  return { action: action as Op["action"], days, byYear };
}

type NoteOp = { icon: string; comment: string; days: string[] };

function cleanNoteText(v: unknown, field: string, max: number): string {
  if (v === undefined) return "";
  if (typeof v !== "string") throw new HttpError(400, `${field} must be a string`);
  const s = v.trim();
  if (s.length > max) throw new HttpError(400, `${field} is too long (max. ${max})`);
  return s;
}

/** A note op; "clear" (or a "set" with nothing left after trimming) has empty icon + comment. */
function parseNoteOp(raw: unknown): NoteOp {
  const o = opObject(raw);
  const action = o.action ?? "set";
  if (action !== "set" && action !== "clear") {
    throw new HttpError(400, "action must be set or clear");
  }
  if (action === "clear") return { icon: "", comment: "", days: parseDays(o) };
  if (o.icon === undefined && o.comment === undefined) {
    throw new HttpError(400, '"set" needs "icon" or "comment"');
  }
  return {
    icon: cleanNoteText(o.icon, "icon", MAX_ICON),
    comment: cleanNoteText(o.comment, "comment", MAX_COMMENT),
    days: parseDays(o),
  };
}

/** Parses `{ops: [...]}` or a single op and enforces the per-request day limit. */
function parseOps<T extends { days: string[] }>(
  body: Record<string, unknown>,
  parse: (raw: unknown) => T,
): { ops: T[]; total: number } {
  const rawOps = Array.isArray(body.ops) ? body.ops : [body];
  const ops = rawOps.map(parse);
  const total = ops.reduce((n, o) => n + o.days.length, 0);
  if (total > MAX_DAYS_PER_REQUEST) throw new HttpError(400, "Too many days in one request");
  return { ops, total };
}

/** Routes /families/{id}/(calendar.ics|types|entries|notes); null for anything else. */
export function handleCalendar(ctx: Ctx): Promise<Response> | null {
  switch (ctx.rest[0]) {
    case "calendar.ics":
      return ctx.rest.length === 1 && ctx.method === "GET" ? calendarFeed(ctx) : null;
    case "types":
      return types(ctx);
    case "entries":
      return ctx.rest.length === 1 ? entries(ctx) : null;
    case "notes":
      return ctx.rest.length === 1 ? notes(ctx) : null;
  }
  return null;
}

async function calendarFeed({ db, store, url, load }: Ctx): Promise<Response> {
  const { family } = await load("feed");
  const withNotes = url.searchParams.get("notes") === "1";
  const [types, rows, notes] = await Promise.all([
    store.listTypes(family.id),
    store.listEntries(family.id),
    withNotes ? store.listNotes(family.id) : undefined,
  ]);
  const entries = new Map<string, string[]>();
  for (const r of rows) {
    const list = entries.get(r.day) ?? [];
    list.push(r.type_id);
    entries.set(r.day, list);
  }
  // A filter matches types by id or name in every year.
  const typesParam = url.searchParams.get("types");
  const include = typesParam ? new Set<TypeRow>() : undefined;
  for (const ref of typesParam?.split(",").filter(Boolean) ?? []) {
    const matches = types.filter((t) => t.id === ref || t.name.toLowerCase() === ref.trim().toLowerCase());
    if (!matches.length) throw new HttpError(404, `Unknown entry type "${ref}"`);
    for (const t of matches) include!.add(t);
  }
  const ics = buildIcs({
    calendarName: url.searchParams.get("name") || family.name,
    // Planners from before families keep their event ids (they were made from the old view id).
    uidPrefix: family.legacy_id ?? family.feed_id,
    types,
    entries,
    include,
    gaps: url.searchParams.get("gaps") === "1",
    notes: notes && new Map(notes.map((n) => [n.day, n])),
    lang: url.searchParams.get("lang") === "de" ? "de" : "en",
    // Booked appointments and other timed events (phase 7), only when asked for.
    events: url.searchParams.get("events") === "1" ? listEvents(db, family.id) : undefined,
    // The members' birthdays, only when asked for.
    birthdays:
      url.searchParams.get("birthdays") === "1"
        ? familyNames(db, family.id).flatMap((p) => (p.birthday ? [{ id: p.id, name: p.name, birthday: p.birthday }] : []))
        : undefined,
  });
  return new Response(ics, {
    headers: {
      ...CORS,
      "content-type": "text/calendar; charset=utf-8",
      "content-disposition": 'inline; filename="calendar.ics"',
      "cache-control": "max-age=300",
    },
  });
}

async function types({ store, req, url, method, rest, loadWith, now }: Ctx): Promise<Response> {
  const write = !(rest.length === 1 && method === "GET");
  const [{ family }, all] = await loadWith(write ? "edit" : "view", (id) => store.listTypes(id));
  const body = write ? await readBody(req) : {};

  if (rest.length === 2 && rest[1] === "copy" && method === "POST") {
    // Copies a year's types into another year; types the target already has are kept.
    const from = cleanYear(body.from, "from");
    const to = cleanYear(body.to, "to");
    const source = all.filter((t) => t.year === from);
    if (!source.length) throw new HttpError(404, `${from} has no entry types`);
    const target = all.filter((t) => t.year === to);
    const taken = new Set(target.map((t) => t.id));
    let position = target.reduce((m, t) => Math.max(m, t.position + 1), 0);
    const copies = source
      .filter((t) => !taken.has(t.id))
      .slice(0, Math.max(0, MAX_TYPES - target.length))
      .map((t) => ({ ...t, year: to, position: position++ }));
    await store.upsertTypes(copies);
    return json([...target, ...copies].map(publicType));
  }

  const year = typesYear(url, body, now);
  const types = all.filter((t) => t.year === year);
  if (!write) return json(types.map(publicType));

  if (rest.length === 1 && method === "POST") {
    if (types.length >= MAX_TYPES) throw new HttpError(400, "Too many entry types");
    const name = cleanName(body.name);
    const type: TypeRow = {
      family_id: family.id,
      year,
      id: uniqueId(slug(name), new Set(types.map((t) => t.id))),
      name,
      color: cleanColor(body.color),
      role: cleanRole(body.role),
      position: types.reduce((m, t) => Math.max(m, t.position + 1), 0),
      away: cleanAway(body.away),
    };
    await store.upsertTypes([type]);
    return json(publicType(type), 201);
  }

  if (rest.length === 2) {
    const type = resolveType(types, rest[1], year);
    if (method === "PATCH") {
      const next = { ...type };
      if (body.name !== undefined) next.name = cleanName(body.name);
      if (body.color !== undefined) next.color = cleanColor(body.color);
      if (body.role !== undefined) next.role = cleanRole(body.role);
      if (body.away !== undefined) next.away = cleanAway(body.away);
      if (body.position !== undefined) {
        if (!Number.isInteger(body.position)) {
          throw new HttpError(400, "position must be an integer");
        }
        next.position = body.position as number;
      }
      await store.upsertTypes([next]);
      return json(publicType(next));
    }
    if (method === "DELETE") {
      await store.deleteType(family.id, year, type.id);
      return json({ deleted: type.id, year });
    }
  }
  throw new HttpError(405, "Method not allowed");
}

async function entries({ store, req, url, method, loadWith }: Ctx): Promise<Response> {
  if (method === "GET") {
    const { from, to } = rangeFromQuery(url);
    const [, rows] = await loadWith("view", (id) => store.listEntries(id, from, to));
    return json(groupEntries(rows));
  }
  if (method !== "POST") throw new HttpError(405, "Method not allowed");
  const [{ family }, types] = await loadWith("edit", (id) => store.listTypes(id));
  const { ops, total } = parseEntryOps(await readBody(req), types);
  await applyEntryOps(store, family.id, ops);
  return json({ ok: true, ops: ops.length, days: total });
}

export type EntryOps = ReturnType<typeof parseEntryOps>;

/** Parses `{ops: [...]}` or one entry op against all types of the family. */
export function parseEntryOps(body: Record<string, unknown>, types: TypeRow[]) {
  return parseOps(body, (o) => parseOp(o, types));
}

export async function applyEntryOps(store: Store, familyId: string, ops: EntryOps["ops"]) {
  for (const { action, byYear } of ops) {
    for (const { types, days } of byYear) {
      if (action === "clear" || action === "set") {
        await store.removeEntries(familyId, days);
      } else if (action === "remove") {
        await store.removeEntries(familyId, days, types);
      }
      if ((action === "add" || action === "set") && types.length) {
        await store.addEntries(
          familyId,
          days.flatMap((day) => types.map((type_id) => ({ day, type_id }))),
        );
      }
    }
  }
}

/** Parses `{ops: [...]}` or one note op. */
export function parseNoteOps(body: Record<string, unknown>) {
  return parseOps(body, parseNoteOp);
}

export async function applyNoteOps(store: Store, familyId: string, ops: ReturnType<typeof parseNoteOps>["ops"]) {
  for (const { icon, comment, days } of ops) {
    if (icon || comment) {
      await store.upsertNotes(
        familyId,
        days.map((day) => ({ day, icon, comment })),
      );
    } else {
      await store.removeNotes(familyId, days);
    }
  }
}

async function notes({ store, req, url, method, load, loadWith }: Ctx): Promise<Response> {
  if (method === "GET") {
    const { from, to } = rangeFromQuery(url);
    const [, rows] = await loadWith("view", (id) => store.listNotes(id, from, to));
    return json(notesMap(rows));
  }
  if (method !== "POST") throw new HttpError(405, "Method not allowed");
  const { family } = await load("edit");
  const { ops, total } = parseNoteOps(await readBody(req));
  await applyNoteOps(store, family.id, ops);
  return json({ ok: true, ops: ops.length, days: total });
}
