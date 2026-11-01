// The assistant's suggestions (no module: events are the calendar's, which is always on): from
// a letter, a school note, a closure notice or an invitation the user shared (often scanned in
// the app: a text attachment), suggest_items offers the events, tasks and deadlines in it. Like
// edit_reminders it ends the step: the chat shows them as a card (`kind: "suggestions"`), the
// user ticks the ones to add, the app adds the events to the family's calendar (POST /events)
// and the tasks and deadlines to their Reminders (EventKit), and answers (POST
// /ai/chats/{id}/suggestions); that answer is the tool's result.

import { ZodError } from "zod";
import { HttpError } from "@/lib/api/http";
import { isValidDate } from "@/lib/calendar/dates";
import { checkEventFields } from "@/lib/calendar/events";
import type { Tool, ToolContext } from "./common";
import { MAX_REMINDER_NOTES, MAX_REMINDER_TITLE, resolveList } from "./reminders";

/** One suggestion, resolved: an event for the family's calendar (fields POST /events
 *  accepts; endDate only when it differs from date), or a task / deadline for the user's
 *  Reminders (`due` "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM", always there for a deadline; `list` a
 *  Reminders list id with its title, null: the device's default list). */
export type SuggestionOp =
  | {
      op: "event";
      title: string;
      date: string;
      endDate?: string;
      start?: string;
      end?: string;
      location?: string;
      person?: string;
      note?: string;
    }
  | { op: "task" | "deadline"; title: string; due?: string; note?: string; list: string | null; listTitle: string | null };

/** Suggestions waiting for the user to pick the ones to add in the app. */
export interface SuggestionsEdit {
  summary: string;
  /** What the document is ("Elternbrief Klasse 3b"). */
  source?: string;
  ops: SuggestionOp[];
}

export const MAX_SUGGESTIONS = 30;
export const MAX_SOURCE = 200;
const MAX_LOCATION = 200;
/** An event's person (POST /events takes no more). */
const MAX_PERSON = 80;
const MAX_NOTE = MAX_REMINDER_NOTES;
const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;

export const NO_REMINDERS =
  "The user's Reminders aren't available on this device: suggest a deadline as an all-day event instead and mention tasks in your answer";

const present = (v: unknown) => v !== undefined && v !== null && v !== "";

/** Optional text, trimmed (undefined when blank). */
function textArg(v: unknown, field: string, max: number): string | undefined {
  if (!present(v)) return undefined;
  if (typeof v !== "string") throw new HttpError(400, `${field} must be text`);
  const s = v.trim();
  if (s.length > max) throw new HttpError(400, `${field} takes at most ${max} characters`);
  return s || undefined;
}

function titleArg(v: unknown): string {
  const s = typeof v === "string" ? v.trim() : "";
  if (!s) throw new HttpError(400, "title must not be empty");
  if (s.length > MAX_REMINDER_TITLE) throw new HttpError(400, `title takes at most ${MAX_REMINDER_TITLE} characters`);
  return s;
}

function dateArg(v: unknown, field: string, required: boolean): string | undefined {
  if (!present(v)) {
    if (required) throw new HttpError(400, `${field} is required (YYYY-MM-DD)`);
    return undefined;
  }
  if (!isValidDate(v)) throw new HttpError(400, `${field} must be YYYY-MM-DD`);
  return v;
}

function timeArg(v: unknown, field: string): string | undefined {
  if (!present(v)) return undefined;
  if (typeof v !== "string" || !TIME.test(v)) throw new HttpError(400, `${field} must be HH:MM`);
  return v;
}

/** The items of suggest_items, checked and resolved (tasks' and deadlines' lists against the
 *  user's Reminders). */
export function resolveSuggestions(ctx: Pick<ToolContext, "reminders">, raw: unknown): SuggestionOp[] {
  if (!Array.isArray(raw) || !raw.length || raw.length > MAX_SUGGESTIONS) {
    throw new HttpError(400, `items must be a list of 1 to ${MAX_SUGGESTIONS} suggestions`);
  }
  return raw.map((rawItem, i): SuggestionOp => {
    const o = (rawItem && typeof rawItem === "object" ? rawItem : {}) as Record<string, unknown>;
    try {
      switch (o.kind) {
        case "event": {
          const title = titleArg(o.title);
          const date = dateArg(o.date, "date", true)!;
          const endDate = dateArg(o.endDate, "endDate", false);
          const start = timeArg(o.start, "start");
          const end = timeArg(o.end, "end");
          if (end && !start) throw new HttpError(400, "end needs start");
          const op: SuggestionOp = {
            op: "event",
            title,
            date,
            ...(endDate && endDate !== date ? { endDate } : {}),
            ...(start ? { start } : {}),
            ...(end ? { end } : {}),
          };
          const location = textArg(o.location, "location", MAX_LOCATION);
          const person = textArg(o.person, "person", MAX_PERSON);
          const note = textArg(o.note, "note", MAX_NOTE);
          if (location) op.location = location;
          if (person) op.person = person;
          if (note) op.note = note;
          // What POST /events will get: an accepted suggestion is a valid event.
          try {
            checkEventFields({ ...op });
          } catch (err) {
            if (err instanceof ZodError) throw new HttpError(400, err.issues[0]?.message ?? "Not a valid event");
            throw err;
          }
          return op;
        }
        case "task":
        case "deadline": {
          const title = titleArg(o.title);
          const date = dateArg(o.date, "date", o.kind === "deadline");
          const start = timeArg(o.start, "start");
          if (start && !date) throw new HttpError(400, "start (the due time) needs date");
          const note = textArg(o.note, "note", MAX_NOTE);
          if (!ctx.reminders) throw new HttpError(400, NO_REMINDERS);
          const list = present(o.list) ? resolveList(ctx.reminders, o.list) : null;
          return {
            op: o.kind,
            title,
            ...(date ? { due: start ? `${date}T${start}` : date } : {}),
            ...(note ? { note } : {}),
            list: list?.id ?? null,
            listTitle: list?.title ?? null,
          };
        }
        default:
          throw new HttpError(400, "kind must be event, task or deadline");
      }
    } catch (err) {
      if (err instanceof HttpError) throw new HttpError(err.status, `items[${i}]: ${err.message}`);
      throw err;
    }
  });
}

const NOUNS = {
  en: { event: ["event", "events"], task: ["task", "tasks"], deadline: ["deadline", "deadlines"] },
  de: { event: ["Termin", "Termine"], task: ["Aufgabe", "Aufgaben"], deadline: ["Frist", "Fristen"] },
} as const;

/** What the card says: one suggestion by name ("Add “Sports day”"), several by counts ("2
 *  events, 1 task, 1 deadline"), after the document's name if given ("From “Elternbrief”: …"). */
export function suggestionsSummary(ops: SuggestionOp[], lang: "en" | "de", source?: string): string {
  const de = lang === "de";
  let text: string;
  if (ops.length === 1) {
    text = de ? `„${ops[0].title}“ hinzufügen` : `Add “${ops[0].title}”`;
  } else {
    const parts: string[] = [];
    for (const kind of ["event", "task", "deadline"] as const) {
      const k = ops.filter((o) => o.op === kind).length;
      const [one, many] = NOUNS[lang][kind];
      if (k) parts.push(`${k} ${k === 1 ? one : many}`);
    }
    text = parts.join(", ");
  }
  if (!source) return text;
  return de ? `Aus „${source}“: ${text}` : `From “${source}”: ${text}`;
}

export const suggestionTools: Record<string, Tool> = {
  suggest_items: {
    write: true,
    spec: {
      name: "suggest_items",
      description:
        'Offers the events, tasks (to bring, buy, sign …) and deadlines (reply, pay, hand in by …) of a letter, note or invitation the user shared. Like edit_reminders, nothing is added right away: the user ticks which to add (events go to the family\'s calendar, tasks and deadlines to their Reminders). Result: {"applied": true, "results": [{"op", "title", "ok": true, "id"?} | {…, "ok": false, "declined": true} (not picked) | {…, "ok": false, "error"}] (per item, in order)}, {"applied": false} (none added) or {"skipped": true}. All suggestions in one call; no other tools after it in the step, not with ask_user. items: {"kind": "event", "title", "date", "endDate"?, "start"?, "end"? (HH:MM, on endDate; no start: all day), "location"?, "person"? (a family member), "note"?}; {"kind": "task" | "deadline", "title", "date"? (due day; a deadline needs it), "start"? (due time), "note"?, "list"? (Reminders list id or title, or "shopping"; none: the default list)}. Tasks and deadlines need the user\'s Reminders.',
      parameters: {
        type: "object",
        properties: {
          source: { type: "string", description: 'What the document is, e.g. "Elternbrief Klasse 3b"' },
          items: {
            type: "array",
            items: {
              type: "object",
              properties: {
                kind: { type: "string", enum: ["event", "task", "deadline"] },
                title: { type: "string" },
                date: { type: "string", description: "YYYY-MM-DD" },
                endDate: { type: "string" },
                start: { type: "string", description: "HH:MM" },
                end: { type: "string" },
                location: { type: "string" },
                person: { type: "string" },
                note: { type: "string" },
                list: { type: "string" },
              },
              required: ["kind", "title"],
            },
          },
        },
        required: ["items"],
      },
    },
    run(args, ctx) {
      const source = textArg(args.source, "source", MAX_SOURCE);
      const ops = resolveSuggestions(ctx, args.items);
      const summary = suggestionsSummary(ops, ctx.lang, source);
      return Promise.resolve({
        result: { waiting: true },
        summary,
        suggestions: { summary, ...(source ? { source } : {}), ops },
      });
    },
  },
};
