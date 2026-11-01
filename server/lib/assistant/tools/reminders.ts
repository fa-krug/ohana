// The assistant's Reminders tools (no module). The user's Reminders live on their device, so
// the app sends what the assistant may know of them with every message (`reminders` in the
// chat's context: the lists, the open reminders and which list is the family's shopping list);
// without it (no Reminders access on the device) the tools aren't offered.
// get_reminders reads that snapshot. edit_reminders checks its ops against it and then, like
// ask_user, ends the step: the chat shows the changes as a card, the app applies them through
// EventKit once the user says so and answers (POST /ai/chats/{id}/reminders), and that answer
// is the tool's result.

import { HttpError } from "@/lib/api/http";
import { isValidDate } from "@/lib/calendar/dates";
import { fitting, opsSummary, type Tool, type ToolContext } from "./common";

/** What the app tells about the user's Reminders (checked and capped by cleanReminders). */
export interface RemindersSnapshot {
  /** The list the family's shopping items go into on this device; null: none chosen. */
  shoppingListId: string | null;
  lists: { id: string; title: string }[];
  items: ReminderItem[];
}

export interface ReminderItem {
  id: string;
  /** The id of its list. */
  list: string;
  title: string;
  notes?: string;
  /** "YYYY-MM-DD", "YYYY-MM-DDTHH:MM" or null. */
  due: string | null;
  /** Only when true (the app sends open reminders). */
  completed?: true;
}

/** One change of an edit, resolved: `list` is always a list id, with its title, and an op on
 *  an existing reminder names it (`itemTitle`). */
export type ReminderOp =
  | { op: "add"; list: string; listTitle: string; title: string; notes?: string; due?: string }
  | {
      op: "update";
      id: string;
      itemTitle: string;
      /** The reminder's list, or the one it moves to. */
      list: string;
      listTitle: string;
      title?: string;
      notes?: string;
      /** null clears it. */
      due?: string | null;
    }
  | { op: "complete" | "uncomplete" | "delete"; id: string; itemTitle: string; list: string; listTitle: string };

/** A change of the user's Reminders, waiting for their OK in the app. */
export interface RemindersEdit {
  summary: string;
  ops: ReminderOp[];
}

export const MAX_REMINDER_LISTS = 100;
export const MAX_REMINDER_ITEMS = 500;
export const MAX_REMINDER_TITLE = 200;
export const MAX_REMINDER_NOTES = 1000;
export const MAX_REMINDER_OPS = 50;
const MAX_ID = 200;

const DUE = /^(\d{4}-\d{2}-\d{2})(?:T([01]\d|2[0-3]):[0-5]\d)?$/;

/** A due date the app understands ("YYYY-MM-DD" or "YYYY-MM-DDTHH:MM"), else null. */
export function cleanDue(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const m = DUE.exec(v.trim());
  return m && isValidDate(m[1]) ? v.trim() : null;
}

const id = (v: unknown) => (typeof v === "string" && v.length > 0 && v.length <= MAX_ID ? v : null);
const text = (v: unknown, max: number) => (typeof v === "string" ? v.trim().slice(0, max) : "");

/** The app's `reminders`, checked: what doesn't fit is dropped (lists beyond 100, items beyond
 *  500 or of an unknown list, broken entries), titles and notes are cut. undefined: none sent. */
export function cleanReminders(raw: unknown): RemindersSnapshot | undefined {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return undefined;
  const o = raw as Record<string, unknown>;
  const lists: RemindersSnapshot["lists"] = [];
  const listIds = new Set<string>();
  for (const l of Array.isArray(o.lists) ? o.lists : []) {
    if (lists.length >= MAX_REMINDER_LISTS) break;
    const listId = id(l?.id);
    if (!listId || listIds.has(listId)) continue;
    listIds.add(listId);
    lists.push({ id: listId, title: text(l.title, MAX_REMINDER_TITLE) });
  }
  const items: ReminderItem[] = [];
  const itemIds = new Set<string>();
  for (const it of Array.isArray(o.items) ? o.items : []) {
    if (items.length >= MAX_REMINDER_ITEMS) break;
    const itemId = id(it?.id);
    const list = id(it?.list);
    if (!itemId || itemIds.has(itemId) || !list || !listIds.has(list)) continue;
    itemIds.add(itemId);
    const notes = text(it.notes, MAX_REMINDER_NOTES);
    items.push({
      id: itemId,
      list,
      title: text(it.title, MAX_REMINDER_TITLE),
      ...(notes ? { notes } : {}),
      due: cleanDue(it.due),
      ...(it.completed === true ? { completed: true as const } : {}),
    });
  }
  const shopping = id(o.shoppingListId);
  return { shoppingListId: shopping && listIds.has(shopping) ? shopping : null, lists, items };
}

function snapshotOf(ctx: ToolContext): RemindersSnapshot {
  if (!ctx.reminders) throw new HttpError(400, "The user's Reminders aren't available in this chat");
  return ctx.reminders;
}

/** A list by id, title (case ignored) or "shopping" (the family's shopping list). */
function resolveList(r: RemindersSnapshot, ref: unknown): { id: string; title: string } {
  const s = typeof ref === "string" ? ref.trim() : "";
  if (!s) throw new HttpError(400, "list is required");
  const byId = r.lists.find((l) => l.id === s);
  if (byId) return byId;
  const low = s.toLowerCase();
  if (low === "shopping") {
    const list = r.lists.find((l) => l.id === r.shoppingListId);
    if (!list) {
      throw new HttpError(404, "No Reminders list is chosen for the family's shopping list on this device; name a list instead");
    }
    return list;
  }
  const byTitle = r.lists.filter((l) => l.title.toLowerCase() === low);
  if (byTitle.length === 1) return byTitle[0];
  if (byTitle.length > 1) throw new HttpError(400, `Several lists are called "${s}": use the list's id`);
  throw new HttpError(404, `No Reminders list "${s}". The lists are: ${r.lists.map((l) => `“${l.title}”`).join(", ") || "(none)"}`);
}

function resolveItem(r: RemindersSnapshot, ref: unknown): ReminderItem {
  const s = typeof ref === "string" ? ref.trim() : "";
  if (!s) throw new HttpError(400, "id is required (get_reminders gives the ids)");
  const item = r.items.find((i) => i.id === s);
  if (!item) throw new HttpError(404, `No reminder with the id "${s}" (get_reminders gives the ids)`);
  return item;
}

function titleArg(v: unknown, field = "title"): string {
  const s = typeof v === "string" ? v.trim() : "";
  if (!s) throw new HttpError(400, `${field} must not be empty`);
  if (s.length > MAX_REMINDER_TITLE) throw new HttpError(400, `${field} takes at most ${MAX_REMINDER_TITLE} characters`);
  return s;
}

function notesArg(v: unknown): string {
  if (typeof v !== "string") throw new HttpError(400, "notes must be text");
  if (v.length > MAX_REMINDER_NOTES) throw new HttpError(400, `notes take at most ${MAX_REMINDER_NOTES} characters`);
  return v.trim();
}

function dueArg(v: unknown): string {
  const due = cleanDue(v);
  if (!due) throw new HttpError(400, 'due must be "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM"');
  return due;
}

/** The ops of edit_reminders, checked against the snapshot and resolved. */
export function resolveOps(r: RemindersSnapshot, raw: unknown): ReminderOp[] {
  if (!Array.isArray(raw) || !raw.length || raw.length > MAX_REMINDER_OPS) {
    throw new HttpError(400, `ops must be a list of 1 to ${MAX_REMINDER_OPS} changes`);
  }
  return raw.map((rawOp, i): ReminderOp => {
    const o = (rawOp && typeof rawOp === "object" ? rawOp : {}) as Record<string, unknown>;
    try {
      switch (o.op) {
        case "add": {
          const list = resolveList(r, o.list);
          return {
            op: "add",
            list: list.id,
            listTitle: list.title,
            title: titleArg(o.title),
            ...(o.notes !== undefined && o.notes !== null && o.notes !== "" ? { notes: notesArg(o.notes) } : {}),
            ...(o.due !== undefined && o.due !== null && o.due !== "" ? { due: dueArg(o.due) } : {}),
          };
        }
        case "update": {
          const item = resolveItem(r, o.id);
          const list = o.list !== undefined && o.list !== null ? resolveList(r, o.list) : r.lists.find((l) => l.id === item.list)!;
          const op: ReminderOp = { op: "update", id: item.id, itemTitle: item.title, list: list.id, listTitle: list.title };
          if (o.title !== undefined) op.title = titleArg(o.title);
          if (o.notes !== undefined) op.notes = o.notes === null ? "" : notesArg(o.notes);
          if (o.due !== undefined) op.due = o.due === null || o.due === "" ? null : dueArg(o.due);
          if (op.title === undefined && op.notes === undefined && op.due === undefined && list.id === item.list) {
            throw new HttpError(400, "update changes nothing: give title, notes, due or list");
          }
          return op;
        }
        case "complete":
        case "uncomplete":
        case "delete": {
          const item = resolveItem(r, o.id);
          const list = r.lists.find((l) => l.id === item.list)!;
          return { op: o.op, id: item.id, itemTitle: item.title, list: list.id, listTitle: list.title };
        }
        default:
          throw new HttpError(400, "op must be add, update, complete, uncomplete or delete");
      }
    } catch (err) {
      if (err instanceof HttpError) throw new HttpError(err.status, `ops[${i}]: ${err.message}`);
      throw err;
    }
  });
}

/** What the card says the edit does, e.g. "Add 3 reminders to Groceries". */
export function editSummary(ops: ReminderOp[], lang: "en" | "de"): string {
  return opsSummary(ops, lang, {
    noun: { en: ["reminder", "reminders"], de: ["Erinnerung", "Erinnerungen"] },
    verbs: [
      ["add", "add", "hinzufügen"],
      ["update", "change", "ändern"],
      ["complete", "complete", "abhaken"],
      ["uncomplete", "reopen", "wieder öffnen"],
      ["delete", "delete", "löschen"],
    ],
    name: (o) => (o.op === "add" ? o.title : o.itemTitle),
    target: (o) => ({ id: o.list, title: o.listTitle }),
  });
}

export const reminderTools: Record<string, Tool> = {
  get_reminders: {
    needsReminders: true,
    spec: {
      name: "get_reminders",
      description:
        'Reads the user\'s Reminders (Apple Reminders on their device, as the app last sent them): the lists, which one is the family\'s shopping list, and the open reminders (id, list, title, notes, due "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM"). list: a list id or title, or "shopping", to read only that list.',
      parameters: {
        type: "object",
        properties: { list: { type: "string", description: 'A list id or title, or "shopping"' } },
      },
    },
    run(args, ctx) {
      const r = snapshotOf(ctx);
      const only = args.list !== undefined && args.list !== null && args.list !== "" ? resolveList(r, args.list) : null;
      const items = r.items.filter((i) => !only || i.list === only.id);
      const shopping = r.lists.find((l) => l.id === r.shoppingListId) ?? null;
      const head = {
        shoppingList: shopping,
        lists: r.lists.map((l) => ({
          ...l,
          ...(l.id === r.shoppingListId ? { shopping: true } : {}),
          open: r.items.filter((i) => i.list === l.id && !i.completed).length,
        })),
      };
      const shown = fitting(head, items);
      return Promise.resolve({
        result: { ...head, items: shown, ...(shown.length < items.length ? { more: items.length - shown.length } : {}) },
        summary: `${items.length} ${items.length === 1 ? "reminder" : "reminders"}`,
      });
    },
  },

  edit_reminders: {
    write: true,
    needsReminders: true,
    spec: {
      name: "edit_reminders",
      description:
        'Changes the user\'s Reminders (any list; "shopping" is the family\'s shopping list, e.g. to add groceries). Nothing changes right away: the app shows the changes and the user applies or declines them. The result comes back as this tool\'s result: {"applied": true, "results": [{"ok": true, "id": "…"} | {"ok": false, "error": "…"}, …] (one per op, in order)}, {"applied": false} when they declined, or {"skipped": true} when they wrote a new message instead. Put all changes into one call; call no other tools after it in the same step, and don\'t ask a question (ask_user) in the same step. ops, applied in order: {"op": "add", "list": id | title | "shopping", "title", "notes"?, "due"?: "YYYY-MM-DD" | "YYYY-MM-DDTHH:MM"}; {"op": "update", "id", "title"?, "notes"?, "due"? (null clears it), "list"? (moves it)}; {"op": "complete" | "uncomplete" | "delete", "id"}. Ids come from get_reminders.',
      parameters: {
        type: "object",
        properties: {
          ops: {
            type: "array",
            items: {
              type: "object",
              properties: {
                op: { type: "string", enum: ["add", "update", "complete", "uncomplete", "delete"] },
                id: { type: "string", description: "The reminder (not for add)" },
                list: { type: "string", description: 'A list id or title, or "shopping"' },
                title: { type: "string" },
                notes: { type: "string" },
                due: { type: "string", description: '"YYYY-MM-DD" or "YYYY-MM-DDTHH:MM"; null clears it (update)' },
              },
              required: ["op"],
            },
          },
        },
        required: ["ops"],
      },
    },
    run(args, ctx) {
      const r = snapshotOf(ctx);
      const ops = resolveOps(r, args.ops);
      const summary = editSummary(ops, ctx.lang);
      return Promise.resolve({ result: { waiting: true }, summary, reminders: { summary, ops } });
    },
  },
};
