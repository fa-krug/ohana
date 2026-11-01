// The assistant's tools for the calendar's events (phase 7's cal_events: booked doctor's
// appointments and other appointments, one day or several, once or repeating): list, add,
// change, remove. Undo goes through the family API's /events routes: a change is undone by a
// PATCH with the series' previous full state (a split also deletes the new series), a removal
// by POSTing the series back.

import { HttpError } from "@/lib/api/http";
import {
  cleanTarget,
  createSeries,
  deleteSeries,
  eventRange,
  getSeries,
  listOccurrences,
  type Series,
  seriesBody,
  seriesJson,
  updateSeries,
} from "@/lib/calendar/events";
import { fitting, range, type Tool, type UndoStep } from "./common";

const PHRASES = {
  en: {
    added: (t: string, d: string) => `Added “${t}” on ${d}`,
    changed: (t: string, d: string) => `Changed “${t}” on ${d}`,
    removed: (t: string, d: string) => `Removed “${t}” on ${d}`,
  },
  de: {
    added: (t: string, d: string) => `„${t}“ am ${d} eingetragen`,
    changed: (t: string, d: string) => `„${t}“ am ${d} geändert`,
    removed: (t: string, d: string) => `„${t}“ am ${d} entfernt`,
  },
};

const eventProps = {
  date: { type: "string", description: "YYYY-MM-DD, the first day" },
  endDate: { type: "string", description: "YYYY-MM-DD, the last day (several days)" },
  start: { type: "string", description: "HH:MM (none: all day)" },
  end: { type: "string", description: "HH:MM on endDate" },
  title: { type: "string" },
  location: { type: "string" },
  person: { type: "string", description: "A family member's name" },
  note: { type: "string" },
  url: { type: "string" },
  rrule: { type: "string", description: "RRULE value, e.g. FREQ=WEEKLY;BYDAY=MO" },
};

const targetProps = {
  occurrence: { type: "string", description: "A repeating event's occurrence (YYYY-MM-DD)" },
  span: { type: "string", enum: ["this", "future", "all"] },
};

/** The series' text for a change summary: its title and first day. */
const label = (s: Series) => ({ title: s.row.title, day: s.row.day });

export const eventTools: Record<string, Tool> = {
  list_events: {
    spec: {
      name: "list_events",
      description:
        "Lists the occurrences of the calendar's events overlapping two days (max. 3 years). Booked doctor's appointments have source \"appointment\".",
      parameters: {
        type: "object",
        properties: { from: { type: "string" }, to: { type: "string" } },
        required: ["from", "to"],
      },
    },
    async run(args, { db, familyId }) {
      const { from, to } = range(args);
      const events = listOccurrences(db, familyId, eventRange({ from, to }));
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
      description:
        "Adds an event to the calendar. It doesn't change entries or coverage.",
      parameters: { type: "object", properties: eventProps, required: ["date", "title"] },
    },
    async run(args, ctx) {
      const { db, familyId, lang } = ctx;
      const s = createSeries(db, familyId, args, { createdById: ctx.userId ?? null }, ctx.now?.() ?? new Date());
      const { title, day } = label(s);
      return {
        result: seriesJson(s),
        summary: title,
        change: {
          kind: "events",
          summary: PHRASES[lang].added(title, day),
          undo: [{ method: "DELETE", path: `/events/${encodeURIComponent(s.row.id)}` }],
        },
      };
    },
  },

  update_event: {
    write: true,
    spec: {
      name: "update_event",
      description:
        "Changes an event (by id): only the fields given; start null: all day, rrule null: once. A new date for the whole series moves every occurrence.",
      parameters: {
        type: "object",
        properties: { id: { type: "string" }, ...targetProps, ...eventProps },
        required: ["id"],
      },
    },
    async run(args, ctx) {
      const { db, familyId, lang } = ctx;
      const id = String(args.id ?? "");
      const before = getSeries(db, familyId, id);
      if (!before) throw new HttpError(404, `No event "${id}"`);
      const target = cleanTarget(args.occurrence, args.span);
      const { id: _id, occurrence: _o, span: _s, ...body } = args;
      const { series, created } = updateSeries(db, familyId, id, body, target, ctx.now?.() ?? new Date(), ctx.userId ?? null);
      const undo: UndoStep[] = [];
      if (created) undo.push({ method: "DELETE", path: `/events/${encodeURIComponent(series.row.id)}` });
      undo.push({ method: "PATCH", path: `/events/${encodeURIComponent(id)}`, body: seriesBody(before) });
      const { title } = label(series);
      return {
        result: seriesJson(series),
        summary: title,
        change: {
          kind: "events",
          summary: PHRASES[lang].changed(title, target.occurrence ?? series.row.day),
          undo,
        },
      };
    },
  },

  remove_event: {
    write: true,
    spec: {
      name: "remove_event",
      description:
        "Removes an event (by id). For a booked doctor's appointment it doesn't cancel anything with the practice.",
      parameters: {
        type: "object",
        properties: { id: { type: "string" }, ...targetProps },
        required: ["id"],
      },
    },
    async run(args, ctx) {
      const { db, familyId, lang } = ctx;
      const id = String(args.id ?? "");
      const before = getSeries(db, familyId, id);
      if (!before) throw new HttpError(404, `No event "${id}"`);
      const target = cleanTarget(args.occurrence, args.span);
      const after = deleteSeries(db, familyId, id, target, ctx.now?.() ?? new Date());
      const { title, day } = label(before);
      const row = before.row;
      // Back as it was: the whole series again (a booking stays its slot's booking, an event
      // from Apple Calendar stays linked to it), or the series' previous state.
      const undo: UndoStep = after
        ? { method: "PATCH", path: `/events/${encodeURIComponent(id)}`, body: seriesBody(before) }
        : {
            method: "POST",
            path: "/events",
            body: {
              ...seriesBody(before),
              ...(row.source === "appointment" && row.sourceId && row.sourceItem
                ? { searchId: row.sourceId, resultId: row.sourceItem }
                : {}),
              ...(row.source === "apple" && row.sourceItem ? { externalId: row.sourceItem } : {}),
            },
          };
      return {
        result: after ? seriesJson(after) : { deleted: id },
        summary: title,
        change: {
          kind: "events",
          summary: PHRASES[lang].removed(title, target.occurrence ?? day),
          undo: [undo],
        },
      };
    },
  },
};
