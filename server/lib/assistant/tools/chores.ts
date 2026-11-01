// The assistant's tools for the family's chores: list, add, change, remove, mark done. Undo goes
// through the family API's /chores routes: an addition is undone by a DELETE, a change by a
// PATCH with the chore's previous fields, a removal by POSTing the chore back with its id (so
// the reminders the app made for it stay linked); a lost done state comes back with
// POST /chores/{id}/done.

import { HttpError } from "@/lib/api/http";
import {
  type ChorePerson,
  type ChoreRow,
  choreBody,
  chorePeople,
  createChore,
  deleteChore,
  getChoreRow,
  listChores,
  setChoreDone,
  updateChore,
} from "@/lib/chores/chores";
import { fitting, type Tool, type ToolContext, type UndoStep } from "./common";

const PHRASES = {
  en: {
    added: (t: string) => `Added the chore “${t}”`,
    changed: (t: string) => `Changed the chore “${t}”`,
    removed: (t: string) => `Removed the chore “${t}”`,
    done: (t: string) => `Marked “${t}” as done`,
    open: (t: string) => `Marked “${t}” as not done`,
  },
  de: {
    added: (t: string) => `Aufgabe „${t}“ hinzugefügt`,
    changed: (t: string) => `Aufgabe „${t}“ geändert`,
    removed: (t: string) => `Aufgabe „${t}“ entfernt`,
    done: (t: string) => `„${t}“ als erledigt markiert`,
    open: (t: string) => `„${t}“ als nicht erledigt markiert`,
  },
};

const choreProps = {
  title: { type: "string" },
  note: { type: "string" },
  assignee: { type: ["string", "null"], description: "Who does it: a family member's name or id (null: nobody)" },
  day: { type: "string", description: "YYYY-MM-DD: when it is due (a repeating chore's first time)" },
  time: { type: ["string", "null"], description: "HH:MM (none: any time that day)" },
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

/** Marks the chore done again when it was (and the change opened it). */
const doneAgain = (id: string): UndoStep => ({ method: "POST", path: `/chores/${enc(id)}/done`, body: { done: true } });

export const choreTools: Record<string, Tool> = {
  get_chores: {
    spec: {
      name: "get_chores",
      description:
        "Lists the family's chores (with who does them, when they are due next and whether a single one is done) and the people they can be assigned to.",
      parameters: { type: "object", properties: {} },
    },
    async run(_args, ctx) {
      const chores = listChores(ctx.db, ctx.familyId, today(ctx));
      const people = chorePeople(ctx.db, ctx.familyId);
      const shown = fitting({ people }, chores);
      return {
        result: { chores: shown, people, ...(shown.length < chores.length ? { more: chores.length - shown.length } : {}) },
        summary: `${chores.length} chores`,
      };
    },
  },

  add_chore: {
    write: true,
    spec: {
      name: "add_chore",
      description: "Adds a chore: once (due on day) or repeating (rrule), for one family member or nobody.",
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
      deleteChore(ctx.db, ctx.familyId, id);
      const undo: UndoStep[] = [{ method: "POST", path: "/chores", body: { id, ...choreBody(before) } }];
      if (before.doneAt) undo.push(doneAgain(id));
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
        "Marks a single (not repeating) chore as done, or as not done again. A repeating chore's times are ticked off in the user's Reminders.",
      parameters: {
        type: "object",
        properties: { id: { type: "string" }, done: { type: "boolean" } },
        required: ["id", "done"],
      },
    },
    async run(args, ctx) {
      const id = String(args.id ?? "");
      if (typeof args.done !== "boolean") throw new HttpError(400, "done must be true or false");
      const before = requireRow(ctx, id);
      const chore = setChoreDone(ctx.db, ctx.familyId, id, args.done, ctx.now?.() ?? new Date(), today(ctx));
      return {
        result: chore,
        summary: chore.title,
        change: {
          kind: "chores",
          summary: PHRASES[ctx.lang][args.done ? "done" : "open"](chore.title),
          undo: [{ method: "POST", path: `/chores/${enc(id)}/done`, body: { done: !!before.doneAt } }],
        },
      };
    },
  },
};
