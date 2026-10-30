// Routes of the family API for the native app (apple/): the calendar's reads and changes the existing family API doesn't cover.
// Registered before the module's other routes; null for paths that aren't its own.
//
// PATCH /events/{id}: changes a timed event in place (the web app only adds and deletes them;
// the app edits them). The body holds the fields to change (those of POST /events); `start`
// or `end` null clears them, an event without `start` has no `end`. The source (manual or a
// booked appointment) stays. Answers the event as GET /events lists it.

import { and, eq } from "drizzle-orm";
import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, readBody } from "@/lib/api/http";
import { calEvents } from "@/lib/db/schema";
import { eventInputSchema, publicEvent } from "./events";

const EDITABLE = ["date", "start", "end", "title", "location", "person", "note", "url"] as const;

export function handleCalendarApp(ctx: Ctx): Promise<Response> | null {
  if (ctx.rest[0] === "events" && ctx.rest.length === 2 && ctx.method === "PATCH") {
    return updateEvent(ctx, ctx.rest[1]);
  }
  return null;
}

async function updateEvent({ db, req, load }: Ctx, id: string): Promise<Response> {
  const { family } = await load("edit");
  const row = db
    .select()
    .from(calEvents)
    .where(and(eq(calEvents.familyId, family.id), eq(calEvents.id, id)))
    .get();
  if (!row) throw new HttpError(404, "Event not found");
  const body = await readBody(req);
  const current = publicEvent(row);
  const merged: Record<string, unknown> = {};
  for (const key of EDITABLE) merged[key] = key in body ? body[key] : current[key];
  // An all-day event has no end: clearing the start clears the kept end too.
  if (!merged.start && !("end" in body)) merged.end = null;
  const e = eventInputSchema.parse(merged);
  const updated = db
    .update(calEvents)
    .set({
      day: e.date,
      start: e.start ?? null,
      end: e.start ? (e.end ?? null) : null,
      title: e.title,
      location: e.location,
      person: e.person,
      note: e.note,
      url: e.url,
    })
    .where(and(eq(calEvents.familyId, family.id), eq(calEvents.id, id)))
    .returning()
    .get();
  return json(publicEvent(updated));
}
