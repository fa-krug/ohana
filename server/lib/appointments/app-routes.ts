// Routes of the family API for the native app (apple/): /appointments/... searches, runs, results
// and bookings (the pages use server actions; these call the same lib functions with the same
// checks: members read, editors change). Registered before `handleAppointments`; null for paths
// that aren't its own (PATCH / DELETE /appointments/searches/{id} stay with that one).
//
//   GET    /appointments                                   {searches: SearchListItem[], booked: PublicEvent[]}
//   GET    /appointments/options                           {channels, people, home}
//   POST   /appointments/searches                          SearchInput → 201 {id}
//   GET    /appointments/searches/{id}                     {search: SearchListItem, home}
//   GET    /appointments/searches/{id}/runs                {runs: RunWithResults[]}
//   POST   /appointments/searches/{id}/run                 "run now" → {queued: id} (the worker runs it)
//   POST   /appointments/searches/{id}/enabled             {enabled} → {id, enabled}
//   GET    /appointments/searches/{id}/slots/{resultId}    SlotDetailData + {booking, searchEnabled, people, suggestedPerson}
//   POST   /appointments/searches/{id}/slots/{resultId}/book   BookingInput → 201 {eventId, event}
//   POST   /appointments/results/{resultId}/ignore         {searchId}
//   DELETE /appointments/ignored/{entryId}                 {deleted}
//   DELETE /appointments/bookings/{eventId}                {deleted}
//
// The autocompletes (doctolib-specialities, jameda-terms, geocode) are route handlers of their own.

import { eq } from "drizzle-orm";
import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, readBody } from "@/lib/api/http";
import type { Db } from "@/lib/db";
import { families } from "@/lib/db/schema";
import { findBooking, listBookedAppointments, publicEvent } from "@/lib/calendar/events";
import { familyNames } from "@/lib/families/people";
import { listChannelRows } from "@/lib/notifications/channels";
import { type BookingInput, bookSlot, removeBooking, suggestedPerson } from "./booking";
import { searchInputSchema } from "./schema";
import {
  assertSearch,
  createSearch,
  ignoreResult,
  requestRun,
  searchInputOf,
  unignoreEntry,
  updateSearch,
} from "./searches";
import { getSearchDetail, getSlotDetail, listRunsWithResults, listSearchesWithLatest } from "./serialize";

/** The family's home address (distances to the practices; "use home" in the search form). */
export interface HomeDto {
  address: string;
  lat: number;
  lng: number;
}

function homeOf(db: Db, familyId: string): HomeDto | null {
  const row = db
    .select({ address: families.homeAddress, lat: families.homeLat, lng: families.homeLng })
    .from(families)
    .where(eq(families.id, familyId))
    .get();
  if (!row || row.lat === null || row.lng === null) return null;
  return { address: row.address ?? "", lat: row.lat, lng: row.lng };
}

const peopleOf = (db: Db, familyId: string) => familyNames(db, familyId).map((p) => p.name);

function resultIdOf(raw: string): number {
  const id = Number(raw);
  if (!Number.isInteger(id) || id <= 0) throw new HttpError(404, "Not found");
  return id;
}

export function handleAppointmentsApp(ctx: Ctx): Promise<Response> | null {
  const [area, kind, id, sub, subId, action] = ctx.rest;
  if (area !== "appointments") return null;
  const n = ctx.rest.length;
  const m = ctx.method;

  if (n === 1 && m === "GET") return list(ctx);
  if (n === 2 && kind === "options" && m === "GET") return options(ctx);

  if (kind === "searches") {
    if (n === 2 && m === "POST") return create(ctx);
    if (n === 3 && m === "GET") return detail(ctx, id);
    if (n === 4 && sub === "runs" && m === "GET") return runs(ctx, id);
    if (n === 4 && sub === "run" && m === "POST") return runNow(ctx, id);
    if (n === 4 && sub === "enabled" && m === "POST") return setEnabled(ctx, id);
    if (n === 5 && sub === "slots" && m === "GET") return slot(ctx, id, subId);
    if (n === 6 && sub === "slots" && action === "book" && m === "POST") return book(ctx, id, subId);
    // PATCH / DELETE /appointments/searches/{id}: handleAppointments.
    return null;
  }
  if (kind === "results" && n === 4 && sub === "ignore" && m === "POST") return ignore(ctx, id);
  if (kind === "ignored" && n === 3 && m === "DELETE") return unignore(ctx, id);
  if (kind === "bookings" && n === 3 && m === "DELETE") return unbook(ctx, id);
  return null;
}

async function list({ db, load, now }: Ctx): Promise<Response> {
  const { family } = await load("view");
  // From today on, as the web page lists them.
  const today = now.toISOString().slice(0, 10);
  return json({
    searches: listSearchesWithLatest(db, family.id),
    booked: listBookedAppointments(db, family.id, today).map(publicEvent),
  });
}

async function options({ db, load }: Ctx): Promise<Response> {
  const { family } = await load("view");
  return json({
    // As the search form offers them (no secrets).
    channels: listChannelRows(db, family.id).map((c) => ({
      id: c.id,
      name: c.name,
      provider: c.provider,
      enabled: c.enabled,
    })),
    people: peopleOf(db, family.id),
    home: homeOf(db, family.id),
  });
}

async function create({ db, req, load, requireUser, now }: Ctx): Promise<Response> {
  const { family } = await load("edit");
  const input = searchInputSchema.parse(await readBody(req));
  return json(createSearch(db, { id: requireUser().id }, family.id, input, now), 201);
}

async function detail({ db, load }: Ctx, searchId: string): Promise<Response> {
  const { family } = await load("view");
  const search = getSearchDetail(db, family.id, searchId);
  if (!search) throw new HttpError(404, "Search not found");
  return json({ search, home: homeOf(db, family.id) });
}

async function runs({ db, load }: Ctx, searchId: string): Promise<Response> {
  const { family } = await load("view");
  assertSearch(db, family.id, searchId);
  return json({ runs: listRunsWithResults(db, family.id, searchId) });
}

async function runNow({ db, load, requireUser, now }: Ctx, searchId: string): Promise<Response> {
  const { family } = await load("edit");
  requestRun(db, { id: requireUser().id }, family.id, searchId, now);
  return json({ queued: searchId });
}

async function setEnabled({ db, req, load, requireUser, now }: Ctx, searchId: string): Promise<Response> {
  const { family } = await load("edit");
  const body = await readBody(req);
  if (typeof body.enabled !== "boolean") throw new HttpError(400, "enabled must be true or false");
  const row = assertSearch(db, family.id, searchId);
  // The stored search as its input, with only `enabled` changed: same checks and rescheduling
  // as saving the form.
  const input = searchInputSchema.parse({ ...searchInputOf(db, row), enabled: body.enabled });
  updateSearch(db, { id: requireUser().id }, family.id, searchId, input, now);
  return json({ id: searchId, enabled: body.enabled });
}

async function slot({ db, load }: Ctx, searchId: string, rawResultId: string): Promise<Response> {
  const { family } = await load("view");
  const resultId = resultIdOf(rawResultId);
  const data = getSlotDetail(db, family.id, searchId, resultId);
  if (!data) throw new HttpError(404, "Slot not found");
  const booked = findBooking(db, family.id, searchId, resultId);
  const search = assertSearch(db, family.id, searchId);
  const people = peopleOf(db, family.id);
  return json({
    ...data,
    booking: booked
      ? { eventId: booked.id, date: booked.day, start: booked.start, end: booked.end, person: booked.person }
      : null,
    searchEnabled: search.enabled,
    people,
    suggestedPerson: suggestedPerson(db, family.id, search, people),
  });
}

async function book({ db, req, load, requireUser, now }: Ctx, searchId: string, rawResultId: string): Promise<Response> {
  const { family } = await load("edit");
  const resultId = resultIdOf(rawResultId);
  const body = (await readBody(req)) as BookingInput;
  const event = bookSlot(db, { id: requireUser().id }, family.id, searchId, resultId, body, now);
  return json({ eventId: event.id, event: publicEvent(event) }, 201);
}

async function ignore({ db, load, requireUser, now }: Ctx, rawResultId: string): Promise<Response> {
  const { family } = await load("edit");
  return json(ignoreResult(db, { id: requireUser().id }, family.id, resultIdOf(rawResultId), now));
}

async function unignore({ db, load, requireUser }: Ctx, rawEntryId: string): Promise<Response> {
  const { family } = await load("edit");
  const entryId = resultIdOf(rawEntryId);
  unignoreEntry(db, { id: requireUser().id }, family.id, entryId);
  return json({ deleted: entryId });
}

async function unbook({ db, load, requireUser }: Ctx, eventId: string): Promise<Response> {
  const { family } = await load("edit");
  removeBooking(db, { id: requireUser().id }, family.id, eventId);
  return json({ deleted: eventId });
}
