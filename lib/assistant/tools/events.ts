// The assistant's tools for the calendar's timed events (phase 7's cal_events: booked doctor's
// appointments and other appointments with a time): list, add, remove. Undo goes through the
// family API's /events routes.

import { HttpError } from "@/lib/api/http";
import { createEvent, deleteEvent, type EventInput, listEvents, publicEvent } from "@/lib/calendar/events";
import { calEvents } from "@/lib/db/schema";
import { and, eq } from "drizzle-orm";
import { fitting, range, type Tool } from "./common";

const PHRASES = {
  en: {
    added: (t: string, d: string) => `Added “${t}” on ${d}`,
    removed: (t: string, d: string) => `Removed “${t}” on ${d}`,
  },
  de: {
    added: (t: string, d: string) => `„${t}“ am ${d} eingetragen`,
    removed: (t: string, d: string) => `„${t}“ am ${d} entfernt`,
  },
};

const eventProps = {
  date: { type: "string", description: "YYYY-MM-DD" },
  start: { type: "string", description: "HH:MM (leave out for all day)" },
  end: { type: "string", description: "HH:MM" },
  title: { type: "string" },
  location: { type: "string" },
  person: { type: "string", description: "Who it is for" },
  note: { type: "string" },
  url: { type: "string" },
};

export const eventTools: Record<string, Tool> = {
  list_events: {
    spec: {
      name: "list_events",
      description:
        "Lists the calendar's timed events (appointments with a time, place and person, e.g. booked doctor's appointments; source \"appointment\" with the search they came from) between two days.",
      parameters: {
        type: "object",
        properties: { from: { type: "string" }, to: { type: "string" } },
        required: ["from", "to"],
      },
    },
    async run(args, { db, familyId }) {
      const { from, to } = range(args);
      const events = listEvents(db, familyId, { from, to }).map(publicEvent);
      const shown = fitting({ from, to }, events);
      return {
        result: { from, to, events: shown, ...(shown.length < events.length ? { more: events.length - shown.length } : {}) },
        summary: `${events.length} events`,
      };
    },
  },

  add_event: {
    write: true,
    spec: {
      name: "add_event",
      description: "Adds a timed event (an appointment) to the calendar. It doesn't change entries or coverage.",
      parameters: { type: "object", properties: eventProps, required: ["date", "title"] },
    },
    async run(args, ctx) {
      const { db, familyId, lang } = ctx;
      const row = createEvent(db, familyId, args as EventInput, { createdById: ctx.userId ?? null }, ctx.now?.() ?? new Date());
      return {
        result: publicEvent(row),
        summary: row.title,
        change: {
          kind: "events",
          summary: PHRASES[lang].added(row.title, row.day),
          undo: [{ method: "DELETE", path: `/events/${encodeURIComponent(row.id)}` }],
        },
      };
    },
  },

  remove_event: {
    write: true,
    spec: {
      name: "remove_event",
      description:
        "Removes a timed event from the calendar (by id, from list_events). For a booked doctor's appointment it doesn't cancel anything with the practice.",
      parameters: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
    },
    async run(args, { db, familyId, lang }) {
      const id = String(args.id ?? "");
      const row = db.select().from(calEvents).where(and(eq(calEvents.familyId, familyId), eq(calEvents.id, id))).get();
      if (!row || !deleteEvent(db, familyId, id)) throw new HttpError(404, `No event "${id}"`);
      const e = publicEvent(row);
      return {
        result: { deleted: id },
        summary: row.title,
        change: {
          kind: "events",
          summary: PHRASES[lang].removed(row.title, row.day),
          // Back as it was (a booking stays its slot's booking).
          undo: [{
            method: "POST",
            path: "/events",
            body: {
              date: e.date, start: e.start, end: e.end, title: e.title, location: e.location,
              person: e.person, note: e.note, url: e.url,
              ...(row.source === "appointment" && row.sourceId && row.sourceItem
                ? { searchId: row.sourceId, resultId: row.sourceItem }
                : {}),
            },
          }],
        },
      };
    },
  },
};
