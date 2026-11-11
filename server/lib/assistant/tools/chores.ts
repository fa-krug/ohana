// The assistant's tools for the family's chores: list, add, change, remove, mark done (a single
// chore, or one occurrence of a repeating one). Undo goes through the family API's /chores
// routes: an addition is undone by a DELETE, a change by a PATCH with the chore's previous
// fields, a removal by POSTing the chore back with its id and subscribers; a lost done state
// comes back with POST /chores/{id}/done; the day parts with a PATCH of the previous ones.

import { HttpError } from "@/lib/api/http";
import { addDays } from "@/lib/calendar/dates";
import {
  type Chore,
  type ChorePerson,
  type ChoreRow,
  choreBody,
  chorePeople,
  choreSubscriberIds,
  completedDays,
  createChore,
  deleteChore,
  getChoreRow,
  listChores,
  occurrenceDone,
  setChoreDone,
  updateChore,
} from "@/lib/chores/chores";
import { getDayParts, setDayParts } from "@/lib/chores/day-parts";
import { fitting, type Tool, type ToolContext, type UndoStep } from "./common";

const PHRASES = {
  en: {
    added: (t: string) => `Added the chore “${t}”`,
    changed: (t: string) => `Changed the chore “${t}”`,
    removed: (t: string) => `Removed the chore “${t}”`,
    done: (t: string) => `Marked “${t}” as done`,
    open: (t: string) => `Marked “${t}” as not done`,
    dayParts: "Changed when the parts of the day start",
  },
  de: {
    added: (t: string) => `Aufgabe „${t}“ hinzugefügt`,
    changed: (t: string) => `Aufgabe „${t}“ geändert`,
    removed: (t: string) => `Aufgabe „${t}“ entfernt`,
    done: (t: string) => `„${t}“ als erledigt markiert`,
    open: (t: string) => `„${t}“ als nicht erledigt markiert`,
    dayParts: "Beginn der Tageszeiten geändert",
  },
};

const choreProps = {
  title: { type: "string" },
  note: { type: "string" },
  assignee: { type: ["string", "null"], description: "Who does it: a family member's name or id (null: nobody)" },
  day: { type: "string", description: "YYYY-MM-DD: when it is due (a repeating chore's first time)" },
  time: { type: ["string", "null"], description: "HH:MM (none: any time that day; sets the part of the day)" },
  part: { type: "string", enum: ["morning", "day", "evening"], description: "Part of the day, for a chore without a time (default day); due when the part starts" },
  rrule: { type: ["string", "null"], description: "RRULE value, e.g. FREQ=WEEKLY;BYDAY=SA (none: once)" },
};

const today = (ctx: ToolContext) => ctx.today ?? (ctx.now?.() ?? new Date()).toISOString().slice(0, 10);

const enc = encodeURIComponent;

/** The assignee by name (case ignored) or id; 400 for anyone else. */
function assigneeId(people: ChorePerson[], v: unknown): string | null {
  if (v === null || v === "") return null;
  const s = String(v).trim();
  const p = people.find((x) => x.id === s) ?? people.find((x) => x.name.toLocaleLowerCase() === s.toLocaleLowerCase());
  if (!p) throw new HttpError(400, `“${s}” isn't a member of the family (members: ${people.map((x) => x.name).join(", ")})`);
  return p.id;
}

/** The tool's arguments as a /chores body: `assignee` (a name or id) becomes `assigneeId`. */
function bodyOf(args: Record<string, unknown>, ctx: ToolContext): Record<string, unknown> {
  const { id: _id, assignee, ...body } = args;
  return "assignee" in args ? { ...body, assigneeId: assigneeId(chorePeople(ctx.db, ctx.familyId), assignee) } : body;
}

function requireRow(ctx: ToolContext, id: string): ChoreRow {
  const row = getChoreRow(ctx.db, ctx.familyId, id);
  if (!row) throw new HttpError(404, `No chore "${id}"`);
  return row;
}

/** How far back get_chores lists a repeating chore's ticked-off occurrences. */
const DONE_DAYS = 14;

/** A chore as get_chores lists it: names instead of people, no ids of the subscribers. */
function compact(c: Chore, doneOn: string[] | undefined, people: ChorePerson[]) {
  return {
    id: c.id,
    title: c.title,
    ...(c.note ? { note: c.note } : {}),
    assignee: c.assignee?.name ?? null,
    day: c.day,
    time: c.time,
    part: c.part,
    rrule: c.rrule,
    next: c.next,
    ...(c.rrule ? { doneOn: doneOn ?? [] } : { done: c.done, ...(c.doneBy ? { doneBy: c.doneBy.name } : {}) }),
    notified: c.subscriberIds.map((id) => people.find((p) => p.id === id)?.name ?? id),
  };
}

/** Marks the chore done again when it was (and the change opened it). */
const doneAgain = (id: string): UndoStep => ({ method: "POST", path: `/chores/${enc(id)}/done`, body: { done: true } });

export const choreTools: Record<string, Tool> = {
  get_chores: {
    spec: {
      name: "get_chores",
      description:
        "Lists the family's chores (who does them, part of the day, when they are due next, whether a single one is done, the days a repeating one was done in the last two weeks, who gets a notification), the people they can be assigned to and when the family's parts of the day start (dayParts).",
      parameters: { type: "object", properties: {} },
    },
    async run(_args, ctx) {
      const day = today(ctx);
      const people = chorePeople(ctx.db, ctx.familyId);
      const all = listChores(ctx.db, ctx.familyId, day, ctx.userId ?? null);
      const done = completedDays(ctx.db, all.filter((c) => c.rrule).map((c) => c.id), addDays(day, -DONE_DAYS), day);
      const chores = all.map((c) => compact(c, done.get(c.id), people));
      const dayParts = getDayParts(ctx.db, ctx.familyId);
      const shown = fitting({ people, dayParts }, chores);
      return {
        result: { chores: shown, people, dayParts, ...(shown.length < chores.length ? { more: chores.length - shown.length } : {}) },
        summary: `${chores.length} chores`,
      };
    },
  },

  add_chore: {
    write: true,
    spec: {
      name: "add_chore",
      description:
        "Adds a chore: once (due on day) or repeating (rrule), for one family member or nobody, at a time or in a part of the day. The user gets a notification when it is due.",
      parameters: { type: "object", properties: choreProps, required: ["title", "day"] },
    },
    async run(args, ctx) {
      const chore = createChore(ctx.db, ctx.familyId, bodyOf(args, ctx), { createdById: ctx.userId ?? null }, ctx.now?.() ?? new Date(), today(ctx));
      return {
        result: chore,
        summary: chore.title,
        change: {
          kind: "chores",
          summary: PHRASES[ctx.lang].added(chore.title),
          undo: [{ method: "DELETE", path: `/chores/${enc(chore.id)}` }],
        },
      };
    },
  },

  update_chore: {
    write: true,
    spec: {
      name: "update_chore",
      description:
        "Changes a chore (by id): only the fields given; assignee null: nobody, time null: any time, rrule null: once.",
      parameters: { type: "object", properties: { id: { type: "string" }, ...choreProps }, required: ["id"] },
    },
    async run(args, ctx) {
      const id = String(args.id ?? "");
      const before = requireRow(ctx, id);
      const chore = updateChore(ctx.db, ctx.familyId, id, bodyOf(args, ctx), ctx.now?.() ?? new Date(), today(ctx));
      const undo: UndoStep[] = [{ method: "PATCH", path: `/chores/${enc(id)}`, body: choreBody(before) }];
      if (before.doneAt && !chore.done) undo.push(doneAgain(id));
      return {
        result: chore,
        summary: chore.title,
        change: { kind: "chores", summary: PHRASES[ctx.lang].changed(chore.title), undo },
      };
    },
  },

  remove_chore: {
    write: true,
    spec: {
      name: "remove_chore",
      description: "Removes a chore (by id).",
      parameters: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
    },
    async run(args, ctx) {
      const id = String(args.id ?? "");
      const before = requireRow(ctx, id);
      const subscribers = choreSubscriberIds(ctx.db, id);
      deleteChore(ctx.db, ctx.familyId, id);
      const undo: UndoStep[] = [{ method: "POST", path: "/chores", body: { id, ...choreBody(before, subscribers) } }];
      if (!before.rrule && before.doneAt) undo.push(doneAgain(id));
      return {
        result: { deleted: id },
        summary: before.title,
        change: { kind: "chores", summary: PHRASES[ctx.lang].removed(before.title), undo },
      };
    },
  },

  set_chore_done: {
    write: true,
    spec: {
      name: "set_chore_done",
      description:
        "Marks a chore as done, or as not done again: a single chore as a whole, a repeating one for one of its days (day, an occurrence).",
      parameters: {
        type: "object",
        properties: {
          id: { type: "string" },
          done: { type: "boolean" },
          day: { type: "string", description: "YYYY-MM-DD: the occurrence of a repeating chore (not for a single one)" },
        },
        required: ["id", "done"],
      },
    },
    async run(args, ctx) {
      const id = String(args.id ?? "");
      if (typeof args.done !== "boolean") throw new HttpError(400, "done must be true or false");
      const before = requireRow(ctx, id);
      const day = before.rrule ? args.day : undefined;
      const was = typeof day === "string" ? occurrenceDone(ctx.db, id, day) : !!before.doneAt;
      const chore = setChoreDone(ctx.db, ctx.familyId, id, args.done, { day, userId: ctx.userId ?? null }, ctx.now?.() ?? new Date(), today(ctx));
      return {
        result: chore,
        summary: chore.title,
        change: {
          kind: "chores",
          summary: PHRASES[ctx.lang][args.done ? "done" : "open"](before.rrule ? `${chore.title}, ${String(day)}` : chore.title),
          undo: [{ method: "POST", path: `/chores/${enc(id)}/done`, body: { done: was, ...(before.rrule ? { day } : {}) } }],
        },
      };
    },
  },

  set_day_parts: {
    write: true,
    spec: {
      name: "set_day_parts",
      description:
        "Changes when the family's parts of the day start (HH:MM, morning before day before evening; only those given). A chore's time puts it in the part it falls in (before the day's start: morning), and a chore without a time is due when its part starts.",
      parameters: {
        type: "object",
        properties: {
          morning: { type: "string", description: "HH:MM: when the morning starts" },
          day: { type: "string", description: "HH:MM: when the day starts (the morning ends)" },
          evening: { type: "string", description: "HH:MM: when the evening starts" },
        },
      },
    },
    async run(args, ctx) {
      const before = getDayParts(ctx.db, ctx.familyId);
      const dayParts = setDayParts(ctx.db, ctx.familyId, args, ctx.now?.() ?? new Date());
      return {
        result: { dayParts },
        summary: `${dayParts.morning} · ${dayParts.day} · ${dayParts.evening}`,
        change: {
          kind: "chores",
          summary: PHRASES[ctx.lang].dayParts,
          undo: [{ method: "PATCH", path: "/chores/day-parts", body: before }],
        },
      };
    },
  },
};
