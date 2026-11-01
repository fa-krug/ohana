// The family-wide routes of family-planner's API that belong to the calendar (from its
// _shared/families.ts): the family with its calendar (GET /families/{id}), renaming it, and
// export / import of the calendar. Members, invites, creating and deleting
// families are Ohana's own (server actions), so they aren't here.

import type { Ctx, Loaded } from "@/lib/api/family-api";
import { HttpError, json, NO_STORE, readBody, slug } from "@/lib/api/http";
import { renameFamily } from "@/lib/families/manage";
import { exportFinance, parseFinanceImport } from "@/lib/finance/finance";
import type { FamilyRow } from "./store";
import type { Db } from "@/lib/db";
import { type BirthdayDay, birthdaysIn } from "@/lib/families/birthdays";
import { familyNames } from "@/lib/families/people";
import { eventRange, eventsByDay, listOccurrences, type PublicEvent } from "./events";
import { EXPORT_FORMAT, EXPORT_VERSION, isExportFormat } from "./export-file";
import {
  groupEntries,
  listVacation,
  notesMap,
  parseVacationImport,
  publicType,
  type Range,
  rangeFromQuery,
  type VacationData,
  vacationState,
} from "./vacation";

/** The family as the app sees it. */
export function publicFamily({ family, access }: Loaded) {
  return {
    id: family.id,
    name: family.name,
    access,
    readOnly: access !== "edit",
    updatedAt: family.updated_at,
  };
}

/** What the calendar shows next to the entries: events and the members' birthdays. */
export interface DayExtras {
  /** The days the events were listed for. */
  range: { from: string; to: string };
  /** The occurrences overlapping `range`. */
  events: PublicEvent[];
  birthdays: BirthdayDay[];
}

/** The range's events (a missing end: the year of the other one, else the current year; at
 *  most 3 years), and its birthdays when the range has both ends. */
export function dayExtras(db: Db, familyId: string, range: Range, now?: Date): DayExtras {
  const events = eventRange(range, now);
  return {
    range: events,
    events: listOccurrences(db, familyId, events),
    birthdays: range.from && range.to ? birthdaysIn(familyNames(db, familyId), range.from, range.to) : [],
  };
}

/** GET /families/{id}: the family and its calendar in the range, with the events (`events`:
 *  day -> the occurrences covering it) and the members' birthdays (`birthdays`: day ->
 *  [{name, age}]) of the range by day when given. */
export function familyState(loaded: Loaded, range: Range, data: VacationData, extras?: DayExtras) {
  const family = publicFamily(loaded);
  // "session" is the name from before families, kept for scripts that read it.
  return {
    family,
    session: family,
    ...vacationState(range, data),
    ...(extras ? { events: eventsByDay(extras.events, extras.range), birthdays: birthdaysByDay(extras.birthdays) } : {}),
  };
}

function birthdaysByDay(rows: BirthdayDay[]): Record<string, { name: string; age: number }[]> {
  const out: Record<string, { name: string; age: number }[]> = {};
  for (const b of rows) (out[b.day] ??= []).push({ name: b.name, age: b.age });
  return out;
}

/** The whole family as a file: all years, types, entries and notes, and the finances, but
 *  never its ids. */
export function exportData(
  family: FamilyRow,
  [types, rows, notes]: VacationData,
  finance: Awaited<ReturnType<typeof exportFinance>>,
  now: Date,
) {
  return {
    format: EXPORT_FORMAT,
    version: EXPORT_VERSION,
    exportedAt: now.toISOString(),
    name: family.name,
    types: types.map(publicType),
    entries: groupEntries(rows),
    notes: notesMap(notes),
    finance,
  };
}

/** Validates an export file. A file without finances (version 1) leaves them as they are. */
export function parseImport(body: Record<string, unknown>, familyId: string) {
  if (!isExportFormat(body.format)) {
    throw new HttpError(400, "Not a Family Planner export");
  }
  if (body.version !== 1 && body.version !== EXPORT_VERSION) {
    throw new HttpError(400, `Unsupported export version ${body.version}`);
  }
  return {
    ...parseVacationImport(body),
    finance: body.finance === undefined ? undefined : parseFinanceImport(body.finance, familyId),
  };
}

/** Routes /families/{id} and its family-wide sub-paths; null for anything else. */
export function handleFamily(ctx: Ctx): Promise<Response> | null {
  const { rest, method } = ctx;
  if (rest.length === 0) {
    if (method === "GET") return read(ctx);
    if (method === "PATCH") return rename(ctx);
    return Promise.reject(new HttpError(405, "Method not allowed"));
  }
  if (rest.length > 1) return null;
  const route = (
    {
      export: { GET: exportFamily },
      import: { POST: importFamily },
    } as Record<string, Record<string, (ctx: Ctx) => Promise<Response>>>
  )[rest[0]];
  if (!route) return null;
  const fn = route[method];
  return fn ? fn(ctx) : Promise.reject(new HttpError(405, "Method not allowed"));
}

async function read({ db, store, url, loadWith, now }: Ctx): Promise<Response> {
  const range = rangeFromQuery(url);
  const [loaded, data] = await loadWith("view", (id) => listVacation(store, id, range));
  return json(familyState(loaded, range, data, dayExtras(db, loaded.family.id, range, now)));
}

async function rename({ db, store, req, url, loadWith, now, requireUser }: Ctx): Promise<Response> {
  const range = rangeFromQuery(url);
  const [loaded, data] = await loadWith("edit", (id) => listVacation(store, id, range));
  const name = (await readBody(req)).name;
  if (typeof name !== "string") throw new HttpError(400, "name is required");
  renameFamily(db, { id: requireUser().id }, loaded.family.id, name, now);
  const family = (await store.getFamily(loaded.family.id))!;
  return json(familyState({ ...loaded, family }, range, data, dayExtras(db, family.id, range, now)));
}

/** Viewers may export too: they can read all of that anyway. */
async function exportFamily({ store, finance, loadWith, now }: Ctx): Promise<Response> {
  const [{ family }, data] = await loadWith("view", (id) => listVacation(store, id, {}));
  return json(exportData(family, data, await exportFinance(finance, family.id), now), 200, {
    ...NO_STORE,
    "content-disposition": `attachment; filename="${slug(family.name)}.json"`,
  });
}

/** Replaces all years, types, entries and notes, and the finances if the file has them, with
 *  those of an export file; the name stays. Answers like GET /families/{id} (with ?year= etc.). */
async function importFamily({ db, store, req, url, load, now }: Ctx): Promise<Response> {
  const range = rangeFromQuery(url);
  const loaded = await load("edit");
  const { family } = loaded;
  const data = parseImport(await readBody(req), family.id);
  const types = data.types.map((t) => ({ ...t, family_id: family.id }));
  await store.replaceContents(family.id, types, data.entries, data.notes, data.finance);
  const updated = (await store.getFamily(family.id))!;
  return json(
    familyState({ ...loaded, family: updated }, range, await listVacation(store, family.id, range), dayExtras(db, family.id, range, now)),
  );
}
