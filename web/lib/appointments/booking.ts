// Appointments → Calendar (phase 7): a slot the family booked (on Doctolib / jameda, outside
// Ohana) is marked as booked here and becomes a timed event in the calendar. The slot's
// details are copied into the event (results are pruned after 30 days; the event stays).
// Optionally the search stops watching (it is turned off).

import { and, eq } from "drizzle-orm";
import { z } from "zod";
import type { Db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { apptResults, apptRuns, apptSearches, calEvents } from "@/lib/db/schema";
import { type Actor, requireRole } from "@/lib/families/roles";
import { createEvent, type EventRow, findBooking } from "@/lib/calendar/events";
import { assertSearch } from "./searches";

export const bookingInputSchema = z.object({
  /** The day and time as booked (the slot's, unless the practice gave another). */
  date: z.string(),
  start: z.string(),
  end: z.string().nullish(),
  person: z.string().trim().max(80).optional().default(""),
  note: z.string().trim().max(1000).optional().default(""),
  /** Turn the search off: the family has its appointment. */
  stopSearch: z.boolean().optional().default(false),
});

export type BookingInput = z.input<typeof bookingInputSchema>;

/** Marks a slot of the family's search as booked: a calendar event (once per slot). */
export function bookSlot(
  db: Db,
  actor: Actor,
  familyId: string,
  searchId: string,
  resultId: number,
  raw: BookingInput,
  now: Date,
): EventRow {
  requireRole(db, actor, familyId, "editor");
  const search = assertSearch(db, familyId, searchId);
  const r = db
    .select({ result: apptResults, searchId: apptRuns.searchId })
    .from(apptResults)
    .innerJoin(apptRuns, eq(apptRuns.id, apptResults.runId))
    .where(eq(apptResults.id, resultId))
    .get();
  if (!r || r.searchId !== search.id) throw new AuthError(404, "Slot not found.");
  if (findBooking(db, familyId, searchId, resultId)) throw new AuthError(409, "This slot is booked already.");
  const input = bookingInputSchema.parse(raw);
  const s = r.result;
  const address = [s.practiceAddress, [s.practiceZipcode, s.practiceCity].filter(Boolean).join(" ")]
    .filter(Boolean)
    .join(", ");
  return db.transaction((tx) => {
    const event = createEvent(
      tx as unknown as Db,
      familyId,
      {
        date: input.date,
        start: input.start,
        end: input.end || null,
        title: s.doctorName,
        location: [s.practiceName, address].filter(Boolean).join(", "),
        person: input.person,
        note: [s.motiveLabel, input.note].filter(Boolean).join("\n"),
        url: /^https?:\/\//i.test(s.bookingUrl) ? s.bookingUrl : "",
      },
      { source: "appointment", sourceId: search.id, sourceItem: String(resultId), createdById: actor.id },
      now,
    );
    if (input.stopSearch) {
      tx.update(apptSearches)
        .set({ enabled: false, nextRunAt: null, runRequestedAt: null, updatedAt: now })
        .where(eq(apptSearches.id, search.id))
        .run();
    }
    return event;
  });
}

/** Removes a booked appointment (or any event) from the calendar; editors only. It doesn't
 *  cancel anything with the practice. */
export function removeBooking(db: Db, actor: Actor, familyId: string, eventId: string): void {
  requireRole(db, actor, familyId, "editor");
  const res = db
    .delete(calEvents)
    .where(and(eq(calEvents.familyId, familyId), eq(calEvents.id, eventId)))
    .run();
  if (!res.changes) throw new AuthError(404, "Appointment not found.");
}
