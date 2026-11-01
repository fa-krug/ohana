// The assistant's Apple Calendar tools (no module), built like the Reminders tools
// (reminders.ts): the user's own calendars live on their device (work, personal, shared ones),
// so the app sends a snapshot of them with every message (`appleCalendar` in the chat's
// context: the calendars and the events from a week back to 90 days ahead) when it has full
// calendar access; without it the tools aren't offered. get_apple_calendar reads that snapshot.
// edit_apple_calendar checks its ops against it and then ends the step: the chat shows the
// changes as a card (`kind: "calendar"`), the app applies them through EventKit once the user
// says so and answers (POST /ai/chats/{id}/calendar), and that answer is the tool's result.
// Times are wall-clock times of the device's time zone.

import { HttpError } from "@/lib/api/http";
import { addDays, diffDays, isValidDate } from "@/lib/calendar/dates";
import { normalizeRrule } from "@/lib/calendar/rrule";
import { fitting, opsSummary, type Tool, type ToolContext } from "./common";

/** What the app tells about the user's device calendars (checked and capped by
 *  cleanAppleCalendar). */
export interface AppleCalendarSnapshot {
  /** The days the events are from ("YYYY-MM-DD"; null: the app didn't say). */
  from: string | null;
  to: string | null;
  calendars: AppleCalendar[];
  /** Sorted by start. */
  events: AppleEvent[];
}

export interface AppleCalendar {
  id: string;
  title: string;
  /** The account it belongs to (iCloud, Google, …). */
  account?: string;
  /** Changes are allowed (not subscribed, not read-only). */
  writable: boolean;
  /** The calendar this family's Ohana calendar is synced with on the device. */
  ohana?: true;
}

export interface AppleEvent {
  /** EventKit's id; an occurrence of a repeating event adds "@YYYY-MM-DD" (its original day). */
  id: string;
  /** The id of its calendar. */
  calendar: string;
  title: string;
  allDay: boolean;
  /** "YYYY-MM-DDTHH:MM", or "YYYY-MM-DD" when all day. */
  start: string;
  /** Like start; all day: the last day (inclusive). */
  end: string;
  location?: string;
  notes?: string;
  /** The series' rule (RRULE value) on each occurrence of a repeating event. */
  rrule?: string;
}

/** The event an update or delete is about, as the card shows it. */
interface EventRef {
  id: string;
  eventTitle: string;
  eventStart: string;
  eventEnd: string;
  eventAllDay: boolean;
  /** The event's calendar (an update: or the one it moves to), with its title. */
  calendar: string;
  calendarTitle: string;
  /** Only for an occurrence of a repeating event: it alone, or it and the following ones. */
  span?: "this" | "future";
}

/** One change of an edit, resolved: `calendar` is always a calendar id, with its title; times
 *  are complete (an add always has end and allDay; an update that moves the event has all three). */
export type AppleCalendarOp =
  | {
      op: "add";
      calendar: string;
      calendarTitle: string;
      title: string;
      start: string;
      end: string;
      allDay: boolean;
      location?: string;
      notes?: string;
      rrule?: string;
    }
  | ({
      op: "update";
      title?: string;
      start?: string;
      end?: string;
      allDay?: boolean;
      /** "" clears it. */
      location?: string;
      notes?: string;
    } & EventRef)
  | ({ op: "delete" } & EventRef);

/** A change of the user's device calendars, waiting for their OK in the app. */
export interface AppleCalendarEdit {
  summary: string;
  ops: AppleCalendarOp[];
}

export const MAX_APPLE_CALENDARS = 100;
export const MAX_APPLE_EVENTS = 1000;
export const MAX_APPLE_TITLE = 200;
export const MAX_APPLE_NOTES = 1000;
export const MAX_APPLE_LOCATION = 300;
export const MAX_APPLE_OPS = 50;
const MAX_ID = 300;

const TIMED = /^(\d{4}-\d{2}-\d{2})T(?:[01]\d|2[0-3]):[0-5]\d$/;

/** "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM" (a real day), else null. */
function cleanWhen(v: unknown): { value: string; dateOnly: boolean } | null {
  if (typeof v !== "string") return null;
  const s = v.trim();
  if (isValidDate(s)) return { value: s, dateOnly: true };
  const m = TIMED.exec(s);
  return m && isValidDate(m[1]) ? { value: s, dateOnly: false } : null;
}

const dayOf = (when: string) => when.slice(0, 10);
const addMinutes = (t: string, m: number) => new Date(Date.parse(`${t}:00Z`) + m * 60_000).toISOString().slice(0, 16);
const minutesBetween = (a: string, b: string) => Math.round((Date.parse(`${b}:00Z`) - Date.parse(`${a}:00Z`)) / 60_000);

const id = (v: unknown) => (typeof v === "string" && v.length > 0 && v.length <= MAX_ID ? v : null);
const text = (v: unknown, max: number) => (typeof v === "string" ? v.trim().slice(0, max) : "");

/** The app's `appleCalendar`, checked: what doesn't fit is dropped (calendars beyond 100,
 *  events beyond 1000 or of an unknown calendar, broken entries), texts are cut, a rule Ohana
 *  doesn't understand is left out. undefined: none sent. */
export function cleanAppleCalendar(raw: unknown): AppleCalendarSnapshot | undefined {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return undefined;
  const o = raw as Record<string, unknown>;
  const calendars: AppleCalendar[] = [];
  const calendarIds = new Set<string>();
  for (const c of Array.isArray(o.calendars) ? o.calendars : []) {
    if (calendars.length >= MAX_APPLE_CALENDARS) break;
    const calId = id(c?.id);
    if (!calId || calendarIds.has(calId)) continue;
    calendarIds.add(calId);
    const account = text(c.account, MAX_APPLE_TITLE);
    calendars.push({
      id: calId,
      title: text(c.title, MAX_APPLE_TITLE),
      ...(account ? { account } : {}),
      writable: c.writable === true,
      ...(c.ohana === true ? { ohana: true as const } : {}),
    });
  }
  const events: AppleEvent[] = [];
  const eventIds = new Set<string>();
  for (const e of Array.isArray(o.events) ? o.events : []) {
    if (events.length >= MAX_APPLE_EVENTS) break;
    const eventId = id(e?.id);
    const calendar = id(e?.calendar);
    const start = cleanWhen(e?.start);
    const end = cleanWhen(e?.end);
    if (!eventId || eventIds.has(eventId) || !calendar || !calendarIds.has(calendar) || !start || !end) continue;
    const allDay = start.dateOnly || e.allDay === true;
    const s = allDay ? dayOf(start.value) : start.value;
    const t = allDay ? dayOf(end.value) : end.value;
    if ((!allDay && end.dateOnly) || t < s) continue;
    eventIds.add(eventId);
    const location = text(e.location, MAX_APPLE_LOCATION);
    const notes = text(e.notes, MAX_APPLE_NOTES);
    let rrule: string | null = null;
    try {
      rrule = e.rrule ? normalizeRrule(e.rrule) : null;
    } catch {
      // Not one Ohana understands: the event stays, without its rule.
    }
    events.push({
      id: eventId,
      calendar,
      title: text(e.title, MAX_APPLE_TITLE),
      allDay,
      start: s,
      end: t,
      ...(location ? { location } : {}),
      ...(notes ? { notes } : {}),
      ...(rrule ? { rrule } : {}),
    });
  }
  events.sort((a, b) => (a.start < b.start ? -1 : a.start > b.start ? 1 : 0));
  return {
    from: isValidDate(o.from) ? o.from : null,
    to: isValidDate(o.to) ? o.to : null,
    calendars,
    events,
  };
}

function snapshotOf(ctx: ToolContext): AppleCalendarSnapshot {
  if (!ctx.appleCalendar) throw new HttpError(400, "The user's device calendars aren't available in this chat");
  return ctx.appleCalendar;
}

/** A calendar by id or title (case ignored); `write`: it must allow changes. */
function resolveCalendar(s: AppleCalendarSnapshot, ref: unknown, write = false): AppleCalendar {
  const r = typeof ref === "string" ? ref.trim() : "";
  if (!r) throw new HttpError(400, "calendar is required");
  let cal = s.calendars.find((c) => c.id === r);
  if (!cal) {
    const byTitle = s.calendars.filter((c) => c.title.toLowerCase() === r.toLowerCase());
    if (byTitle.length > 1) throw new HttpError(400, `Several calendars are called "${r}": use the calendar's id`);
    cal = byTitle[0];
  }
  if (!cal) {
    throw new HttpError(404, `No calendar "${r}". The calendars are: ${s.calendars.map((c) => `“${c.title}”`).join(", ") || "(none)"}`);
  }
  if (write) writable(cal);
  return cal;
}

function writable(cal: AppleCalendar) {
  if (!cal.writable) throw new HttpError(400, `The calendar “${cal.title}” is read-only: its events can't be changed`);
}

function resolveEvent(s: AppleCalendarSnapshot, ref: unknown): { event: AppleEvent; calendar: AppleCalendar } {
  const r = typeof ref === "string" ? ref.trim() : "";
  if (!r) throw new HttpError(400, "id is required (get_apple_calendar gives the ids)");
  const event = s.events.find((e) => e.id === r);
  if (!event) throw new HttpError(404, `No event with the id "${r}" (get_apple_calendar gives the ids)`);
  const calendar = s.calendars.find((c) => c.id === event.calendar)!;
  writable(calendar);
  return { event, calendar };
}

function titleArg(v: unknown): string {
  const s = typeof v === "string" ? v.trim() : "";
  if (!s) throw new HttpError(400, "title must not be empty");
  if (s.length > MAX_APPLE_TITLE) throw new HttpError(400, `title takes at most ${MAX_APPLE_TITLE} characters`);
  return s;
}

/** location or notes: "" (or null, on an update) clears them. */
function textArg(v: unknown, field: string, max: number): string {
  if (v === null) return "";
  if (typeof v !== "string") throw new HttpError(400, `${field} must be text`);
  if (v.length > max) throw new HttpError(400, `${field} takes at most ${max} characters`);
  return v.trim();
}

function whenArg(v: unknown, field: string) {
  const when = cleanWhen(v);
  if (!when) throw new HttpError(400, `${field} must be "YYYY-MM-DDTHH:MM" or "YYYY-MM-DD" (all day)`);
  return when;
}

function allDayArg(v: unknown): boolean | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "boolean") throw new HttpError(400, "allDay must be true or false");
  return v;
}

/** An end in the event's kind: all day the last day, timed a time (not before start). */
function endOf(v: unknown, start: string, allDay: boolean): string {
  const end = whenArg(v, "end");
  if (!allDay && end.dateOnly) throw new HttpError(400, 'end of a timed event must be "YYYY-MM-DDTHH:MM"');
  return checkEnd(start, allDay ? dayOf(end.value) : end.value);
}

function checkEnd(start: string, end: string): string {
  if (end < start) throw new HttpError(400, "end must not be before start");
  return end;
}

/** start, end and allDay of a new event (a timed one without end lasts an hour). */
function newTimes(o: Record<string, unknown>) {
  const start = whenArg(o.start, "start");
  const flag = allDayArg(o.allDay);
  if (flag === false && start.dateOnly) throw new HttpError(400, 'a timed event needs start "YYYY-MM-DDTHH:MM"');
  const allDay = flag ?? start.dateOnly;
  const s = allDay ? dayOf(start.value) : start.value;
  const end = present(o.end) ? endOf(o.end, s, allDay) : allDay ? s : addMinutes(s, 60);
  return { start: s, end, allDay };
}

/** start, end and allDay of an event an update moves: a new start without end keeps the
 *  event's length. */
function movedTimes(o: Record<string, unknown>, ev: AppleEvent) {
  const start = present(o.start) ? whenArg(o.start, "start") : null;
  const flag = allDayArg(o.allDay);
  if (flag === false && start?.dateOnly) throw new HttpError(400, 'a timed event needs start "YYYY-MM-DDTHH:MM"');
  const allDay = flag ?? (start ? start.dateOnly : ev.allDay);
  let s: string;
  if (start) s = allDay ? dayOf(start.value) : start.value;
  else if (allDay || !ev.allDay) s = allDay ? dayOf(ev.start) : ev.start;
  else throw new HttpError(400, 'to make an all-day event a timed one, give start "YYYY-MM-DDTHH:MM"');
  let end: string;
  if (present(o.end)) end = endOf(o.end, s, allDay);
  else if (allDay) end = addDays(s, diffDays(dayOf(ev.start), dayOf(ev.end)));
  else end = ev.allDay ? addMinutes(s, 60) : addMinutes(s, minutesBetween(ev.start, ev.end));
  return { start: s, end: checkEnd(s, end), allDay };
}

const present = (v: unknown) => v !== undefined && v !== null && v !== "";

function refOf(event: AppleEvent, calendar: AppleCalendar, span: unknown): EventRef {
  if (span !== undefined && span !== null && span !== "this" && span !== "future") {
    throw new HttpError(400, 'span must be "this" or "future"');
  }
  return {
    id: event.id,
    eventTitle: event.title,
    eventStart: event.start,
    eventEnd: event.end,
    eventAllDay: event.allDay,
    calendar: calendar.id,
    calendarTitle: calendar.title,
    ...(event.rrule ? { span: span === "future" ? "future" : "this" } : {}),
  };
}

/** The ops of edit_apple_calendar, checked against the snapshot and resolved. */
export function resolveCalendarOps(s: AppleCalendarSnapshot, raw: unknown): AppleCalendarOp[] {
  if (!Array.isArray(raw) || !raw.length || raw.length > MAX_APPLE_OPS) {
    throw new HttpError(400, `ops must be a list of 1 to ${MAX_APPLE_OPS} changes`);
  }
  return raw.map((rawOp, i): AppleCalendarOp => {
    const o = (rawOp && typeof rawOp === "object" ? rawOp : {}) as Record<string, unknown>;
    try {
      switch (o.op) {
        case "add": {
          const cal = resolveCalendar(s, o.calendar, true);
          const location = present(o.location) ? textArg(o.location, "location", MAX_APPLE_LOCATION) : "";
          const notes = present(o.notes) ? textArg(o.notes, "notes", MAX_APPLE_NOTES) : "";
          return {
            op: "add",
            calendar: cal.id,
            calendarTitle: cal.title,
            title: titleArg(o.title),
            ...newTimes(o),
            ...(location ? { location } : {}),
            ...(notes ? { notes } : {}),
            ...(present(o.rrule) ? { rrule: normalizeRrule(o.rrule) } : {}),
          };
        }
        case "update": {
          const { event, calendar } = resolveEvent(s, o.id);
          const target = present(o.calendar) ? resolveCalendar(s, o.calendar, true) : calendar;
          const op: AppleCalendarOp = { op: "update", ...refOf(event, target, o.span) };
          if (o.title !== undefined) op.title = titleArg(o.title);
          if ([o.start, o.end, o.allDay].some(present)) Object.assign(op, movedTimes(o, event));
          if (o.location !== undefined) op.location = textArg(o.location, "location", MAX_APPLE_LOCATION);
          if (o.notes !== undefined) op.notes = textArg(o.notes, "notes", MAX_APPLE_NOTES);
          const changes = ["title", "start", "location", "notes"].some((k) => k in op);
          if (!changes && target.id === calendar.id) {
            throw new HttpError(400, "update changes nothing: give title, start, end, allDay, location, notes or calendar");
          }
          return op;
        }
        case "delete": {
          const { event, calendar } = resolveEvent(s, o.id);
          return { op: "delete", ...refOf(event, calendar, o.span) };
        }
        default:
          throw new HttpError(400, "op must be add, update or delete");
      }
    } catch (err) {
      if (err instanceof HttpError) throw new HttpError(err.status, `ops[${i}]: ${err.message}`);
      throw err;
    }
  });
}

/** What the card says the edit does, e.g. "Add “Dentist” to Family". */
export function calendarEditSummary(ops: AppleCalendarOp[], lang: "en" | "de"): string {
  return opsSummary(ops, lang, {
    noun: { en: ["event", "events"], de: ["Termin", "Termine"] },
    verbs: [
      ["add", "add", "hinzufügen"],
      ["update", "change", "ändern"],
      ["delete", "delete", "löschen"],
    ],
    name: (o) => (o.op === "add" ? o.title : o.eventTitle),
    target: (o) => ({ id: o.calendar, title: o.calendarTitle }),
  });
}

function dateArg(v: unknown, field: string): string | null {
  if (!present(v)) return null;
  if (!isValidDate(v)) throw new HttpError(400, `${field} must be YYYY-MM-DD`);
  return v;
}

export const appleCalendarTools: Record<string, Tool> = {
  get_apple_calendar: {
    needsAppleCalendar: true,
    spec: {
      name: "get_apple_calendar",
      description:
        "Reads the user's own device calendars (Apple Calendar, as the app last sent them, about a week back to 90 days ahead): the calendars (writable, ohana: synced with the family's calendar) and their events (id, calendar, title, allDay, start, end, location, notes, rrule) from from to to, of one calendar (id or title) if given.",
      parameters: {
        type: "object",
        properties: {
          from: { type: "string", description: "YYYY-MM-DD" },
          to: { type: "string", description: "YYYY-MM-DD" },
          calendar: { type: "string", description: "A calendar id or title" },
        },
      },
    },
    run(args, ctx) {
      const s = snapshotOf(ctx);
      const from = dateArg(args.from, "from") ?? s.from;
      const to = dateArg(args.to, "to") ?? s.to;
      if (from && to && to < from) throw new HttpError(400, "to must not be before from");
      const only = present(args.calendar) ? resolveCalendar(s, args.calendar) : null;
      const events = s.events.filter(
        (e) => (!only || e.calendar === only.id) && (!from || dayOf(e.end) >= from) && (!to || dayOf(e.start) <= to),
      );
      const outside = (from && s.from && from < s.from) || (to && s.to && to > s.to);
      const head = {
        from,
        to,
        ...(outside ? { note: `The app sent only the events from ${s.from} to ${s.to}` } : {}),
        calendars: s.calendars,
      };
      const shown = fitting(head, events);
      return Promise.resolve({
        result: { ...head, events: shown, ...(shown.length < events.length ? { more: events.length - shown.length } : {}) },
        summary: `${events.length} ${events.length === 1 ? "event" : "events"}`,
      });
    },
  },

  edit_apple_calendar: {
    write: true,
    needsAppleCalendar: true,
    spec: {
      name: "edit_apple_calendar",
      description:
        'Changes the user\'s device calendars (writable ones; not the family\'s). Like edit_reminders: the user applies or declines; the result is {"applied": true, "results": [{"ok": true, "id"?} | {"ok": false, "error"}] (per op)}, {"applied": false} or {"skipped": true}. One call, no other tools after it in the step, not with ask_user. ops, in order: {"op": "add", "calendar": id | title, "title", "start", "end"?, "allDay"?, "location"?, "notes"?, "rrule"?}; {"op": "update", "id", "span"?, "title"?, "start"?, "end"?, "allDay"?, "location"?, "notes"?, "calendar"? (moves it)}; {"op": "delete", "id", "span"?}. start/end "YYYY-MM-DDTHH:MM", or "YYYY-MM-DD" all day (end: the last day); timed without end: 1 hour; a new start without end keeps the length. span "this" | "future" for an occurrence of a repeating event. Ids from get_apple_calendar.',
      parameters: {
        type: "object",
        properties: {
          ops: {
            type: "array",
            items: {
              type: "object",
              properties: {
                op: { type: "string", enum: ["add", "update", "delete"] },
                id: { type: "string" },
                span: { type: "string", enum: ["this", "future"] },
                calendar: { type: "string" },
                title: { type: "string" },
                start: { type: "string" },
                end: { type: "string" },
                allDay: { type: "boolean" },
                location: { type: "string" },
                notes: { type: "string" },
                rrule: { type: "string", description: "RRULE value, e.g. FREQ=WEEKLY;BYDAY=MO" },
              },
              required: ["op"],
            },
          },
        },
        required: ["ops"],
      },
    },
    run(args, ctx) {
      const s = snapshotOf(ctx);
      const ops = resolveCalendarOps(s, args.ops);
      const summary = calendarEditSummary(ops, ctx.lang);
      return Promise.resolve({ result: { waiting: true }, summary, appleCalendar: { summary, ops } });
    },
  },
};
