// Timed events on calendar days (phase 7): booked doctor's appointments (from a slot of an
// appointment search) and events added through the API. They sit next to the year grid's
// entries (no type, no role, no coverage), show up on the overview and, with `events=1`, in the
// calendar feed. REST: GET/POST /families/{id}/events, DELETE /families/{id}/events/{eventId}.

import { randomUUID } from "node:crypto";
import { and, asc, eq, gte, lte } from "drizzle-orm";
import { z } from "zod";
import type { Db } from "@/lib/db";
import { calEvents } from "@/lib/db/schema";
import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, readBody } from "@/lib/api/http";
import { isValidDate } from "./dates";
import { type Range, rangeFromQuery } from "./vacation";

export type EventRow = typeof calEvents.$inferSelect;
export type EventSource = "manual" | "appointment";

const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const blank = (max: number) => z.string().trim().max(max).optional().default("");

/** What an event is made of (POST /events, the booking dialog). `end` needs a `start` and
 *  must not be before it; `url` only http(s). */
export const eventInputSchema = z
  .object({
    date: z.string().refine(isValidDate, "date must be YYYY-MM-DD"),
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
  .refine((e) => !e.end || (!!e.start && e.end >= e.start), { message: "end must be after start", path: ["end"] });

export type EventInput = z.input<typeof eventInputSchema>;

/** An event as the API and the pages see it. */
export interface PublicEvent {
  id: string;
  date: string;
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
}

export function publicEvent(e: EventRow): PublicEvent {
  return {
    id: e.id,
    date: e.day,
    start: e.start,
    end: e.end,
    title: e.title,
    location: e.location,
    person: e.person,
    note: e.note,
    url: e.url,
    source: e.source === "appointment" ? "appointment" : "manual",
    searchId: e.source === "appointment" ? e.sourceId : null,
  };
}

/** The family's events in the range, by day and start time (all-day ones first). */
export function listEvents(db: Db, familyId: string, { from, to }: Range = {}): EventRow[] {
  return db
    .select()
    .from(calEvents)
    .where(
      and(
        eq(calEvents.familyId, familyId),
        from ? gte(calEvents.day, from) : undefined,
        to ? lte(calEvents.day, to) : undefined,
      ),
    )
    .orderBy(asc(calEvents.day), asc(calEvents.start), asc(calEvents.createdAt))
    .all();
}

/** day -> its events, as GET /families/{id} hands them to the calendar page. */
export function eventsByDay(rows: EventRow[]): Record<string, PublicEvent[]> {
  const out: Record<string, PublicEvent[]> = {};
  for (const e of rows) (out[e.day] ??= []).push(publicEvent(e));
  return out;
}

export function createEvent(
  db: Db,
  familyId: string,
  input: EventInput,
  meta: { source?: EventSource; sourceId?: string | null; sourceItem?: string | null; createdById?: string | null },
  now: Date,
): EventRow {
  const e = eventInputSchema.parse(input);
  return db
    .insert(calEvents)
    .values({
      id: randomUUID(),
      familyId,
      day: e.date,
      start: e.start ?? null,
      end: e.start ? (e.end ?? null) : null,
      title: e.title,
      location: e.location,
      person: e.person,
      note: e.note,
      url: e.url,
      source: meta.source ?? "manual",
      sourceId: meta.sourceId ?? null,
      sourceItem: meta.sourceItem ?? null,
      createdById: meta.createdById ?? null,
      createdAt: now,
    })
    .returning()
    .get();
}

/** Deletes one of the family's events; false if it has no such event. */
export function deleteEvent(db: Db, familyId: string, id: string): boolean {
  const res = db
    .delete(calEvents)
    .where(and(eq(calEvents.familyId, familyId), eq(calEvents.id, id)))
    .run();
  return res.changes > 0;
}

/** Events of booked appointments, from `from` on (all if omitted). */
export function listBookedAppointments(db: Db, familyId: string, from?: string): EventRow[] {
  return listEvents(db, familyId, { from }).filter((e) => e.source === "appointment");
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
          eq(calEvents.source, "appointment"),
          eq(calEvents.sourceId, searchId),
          eq(calEvents.sourceItem, String(resultId)),
        ),
      )
      .get() ?? null
  );
}

// ------------------------------------------------------------------ REST

/** Routes /families/{id}/events[/{eventId}]; null for anything else. */
export function handleEvents(ctx: Ctx): Promise<Response> | null {
  if (ctx.rest[0] !== "events" || ctx.rest.length > 2) return null;
  const id = ctx.rest[1];
  if (id === undefined && ctx.method === "GET") return listRoute(ctx);
  if (id === undefined && ctx.method === "POST") return createRoute(ctx);
  if (id !== undefined && ctx.method === "DELETE") return deleteRoute(ctx, id);
  return Promise.reject(new HttpError(405, "Method not allowed"));
}

/** GET /events?year= | ?from=&to= → {events: [...]} */
async function listRoute({ db, url, load }: Ctx): Promise<Response> {
  const range = rangeFromQuery(url);
  const { family } = await load("view");
  return json({ events: listEvents(db, family.id, range).map(publicEvent) });
}

/** POST /events {date, start?, end?, title, location?, person?, note?, url?} → the event */
async function createRoute({ db, req, load, now, principal }: Ctx): Promise<Response> {
  const { family } = await load("edit");
  const body = await readBody(req);
  const row = createEvent(db, family.id, body as EventInput, { createdById: principal?.id }, now);
  return json(publicEvent(row), 201);
}

/** DELETE /events/{id} → {deleted: id} */
async function deleteRoute({ db, load }: Ctx, id: string): Promise<Response> {
  const { family } = await load("edit");
  if (!deleteEvent(db, family.id, id)) throw new HttpError(404, "Event not found");
  return json({ deleted: id });
}
