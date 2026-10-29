// The family-wide routes of family-planner's API that belong to the calendar (from its
// _shared/families.ts): the family with its calendar (GET /families/{id}), renaming it, a new
// feed link, and export / import of the calendar. Members, invites, creating and deleting
// families are Ohana's own (server actions), so they aren't here.

import type { Ctx, Loaded } from "@/lib/api/family-api";
import { HttpError, json, NO_STORE, randomToken, readBody, slug } from "@/lib/api/http";
import { renameFamily } from "@/lib/families/manage";
import type { FamilyPatch, FamilyRow } from "./store";
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

/** Marks the JSON of GET /families/{id}/export, which POST /families/{id}/import reads back. */
export const EXPORT_FORMAT = "family-planner";
/** Files exported before the rename; same content. */
const OLD_EXPORT_FORMAT = "vacation-planner";
/** 2 adds the finances (phase 2 of Ohana); files of version 1 only have the calendar. */
export const EXPORT_VERSION = 2;

/** Links that rotate: the feed link, and the legacy link (only removed). */
const LINKS = ["feed", "legacy"] as const;

/** The family as the app sees it. */
export function publicFamily({ family, access }: Loaded) {
  return {
    id: family.id,
    feedId: family.feed_id,
    ...(access === "edit" && family.legacy_id ? { legacyId: family.legacy_id } : {}),
    name: family.name,
    access,
    readOnly: access !== "edit",
    updatedAt: family.updated_at,
  };
}

/** GET /families/{id}: the family and its calendar in the range. */
export function familyState(loaded: Loaded, range: Range, data: VacationData) {
  const family = publicFamily(loaded);
  // "session" is the name from before families, kept for scripts that read it.
  return { family, session: family, ...vacationState(range, data) };
}

/** The whole calendar as a file: all years, types, entries and notes, but never its ids. */
export function exportData(family: FamilyRow, [types, rows, notes]: VacationData, now: Date) {
  return {
    format: EXPORT_FORMAT,
    version: EXPORT_VERSION,
    exportedAt: now.toISOString(),
    name: family.name,
    types: types.map(publicType),
    entries: groupEntries(rows),
    notes: notesMap(notes),
  };
}

/** Validates an export file. Its finances (`finance`) are left alone until the finance module
 *  reads them. */
export function parseImport(body: Record<string, unknown>) {
  if (body.format !== EXPORT_FORMAT && body.format !== OLD_EXPORT_FORMAT) {
    throw new HttpError(400, "Not a Family Planner export");
  }
  if (body.version !== 1 && body.version !== EXPORT_VERSION) {
    throw new HttpError(400, `Unsupported export version ${body.version}`);
  }
  return parseVacationImport(body);
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
      links: { POST: rotateLink },
    } as Record<string, Record<string, (ctx: Ctx) => Promise<Response>>>
  )[rest[0]];
  if (!route) return null;
  const fn = route[method];
  return fn ? fn(ctx) : Promise.reject(new HttpError(405, "Method not allowed"));
}

async function read({ store, url, loadWith }: Ctx): Promise<Response> {
  const range = rangeFromQuery(url);
  const [loaded, data] = await loadWith("view", (id) => listVacation(store, id, range));
  return json(familyState(loaded, range, data));
}

async function rename({ db, store, req, url, loadWith, now, requireUser }: Ctx): Promise<Response> {
  const range = rangeFromQuery(url);
  const [loaded, data] = await loadWith("edit", (id) => listVacation(store, id, range));
  const name = (await readBody(req)).name;
  if (typeof name !== "string") throw new HttpError(400, "name is required");
  renameFamily(db, { id: requireUser().id }, loaded.family.id, name, now);
  const family = (await store.getFamily(loaded.family.id))!;
  return json(familyState({ ...loaded, family }, range, data));
}

/** POST /families/{id}/links {"link": "feed" | "legacy"}: a new feed id (the old one stops
 *  working), or removes the legacy link. Answers like GET. */
async function rotateLink({ store, req, url, loadWith }: Ctx): Promise<Response> {
  const range = rangeFromQuery(url);
  const [loaded, data] = await loadWith("edit", (id) => listVacation(store, id, range));
  const link = (await readBody(req)).link;
  if (!LINKS.includes(link as (typeof LINKS)[number])) {
    throw new HttpError(400, `link must be one of ${LINKS.join(", ")}`);
  }
  const patch: FamilyPatch = link === "feed" ? { feed_id: randomToken(20) } : { legacy_id: null };
  await store.updateFamily(loaded.family.id, patch);
  const family = (await store.getFamily(loaded.family.id))!;
  return json(familyState({ ...loaded, family }, range, data));
}

/** Viewers may export too: they can read all of that anyway. */
async function exportFamily({ store, loadWith, now }: Ctx): Promise<Response> {
  const [{ family }, data] = await loadWith("view", (id) => listVacation(store, id, {}));
  return json(exportData(family, data, now), 200, {
    ...NO_STORE,
    "content-disposition": `attachment; filename="${slug(family.name)}.json"`,
  });
}

/** Replaces all years, types, entries and notes with those of an export file; the name and
 *  the links stay. Answers like GET /families/{id} (with ?year= etc.). */
async function importFamily({ store, req, url, load }: Ctx): Promise<Response> {
  const range = rangeFromQuery(url);
  const loaded = await load("edit");
  const { family } = loaded;
  const data = parseImport(await readBody(req));
  const types = data.types.map((t) => ({ ...t, family_id: family.id }));
  await store.replaceContents(family.id, types, data.entries, data.notes);
  const updated = (await store.getFamily(family.id))!;
  return json(familyState({ ...loaded, family: updated }, range, await listVacation(store, family.id, range)));
}
