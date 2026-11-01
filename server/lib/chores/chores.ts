// The family's chores: once (due on a day) or repeating (an RRULE, as calendar events have),
// assigned to one person of the family (an account or a member without one) or to nobody. The
// app writes them into a Reminders list; the server stores them and works out what is due next
// (`next`). Only single chores are ever done: a repeating one is done per occurrence in
// Reminders.

import { randomUUID } from "node:crypto";
import { and, eq } from "drizzle-orm";
import { z } from "zod";
import type { Db } from "@/lib/db";
import { chores } from "@/lib/db/schema";
import { HttpError } from "@/lib/api/http";
import { addDays, isValidDate } from "@/lib/calendar/dates";
import { expandRule, normalizeRrule, parseRrule } from "@/lib/calendar/rrule";
import { familyNames } from "@/lib/families/people";

export type ChoreRow = typeof chores.$inferSelect;

/** Someone a chore can be assigned to (familyNames). */
export interface ChorePerson {
  id: string;
  name: string;
  account: boolean;
}

export interface Chore {
  id: string;
  title: string;
  note: string;
  assignee: ChorePerson | null;
  day: string;
  time: string | null;
  rrule: string | null;
  /** Single chores only; always false when repeating. */
  done: boolean;
  doneAt: string | null;
  /** Single: `day` while open (also when past), null when done; repeating: the first
   *  occurrence on or after today, null once the series ended. */
  next: string | null;
  /** Repeating: the last occurrence before today, today's and the first after today (those
   *  there are), ascending; the app writes each into Reminders 3 h before it's due. Single: []. */
  occurrences: string[];
  createdAt: string;
  /** Edits only, not done. */
  updatedAt: string;
}

const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
/** Ids a restored chore (the assistant's undo) may bring along. */
const ID_RE = /^[A-Za-z0-9-]{1,64}$/;

/** A chore's fields as POST /chores takes them (PATCH: merged into the stored ones first). */
const inputSchema = z.object({
  title: z.string().trim().min(1, "title is required").max(200, "title is too long (max. 200)"),
  note: z.string().trim().max(2000, "note is too long (max. 2000)").optional().default(""),
  assigneeId: z.string().nullish(),
  day: z.string().refine(isValidDate, "day must be YYYY-MM-DD"),
  time: z.string().regex(TIME_RE, "time must be HH:MM").nullish(),
  rrule: z.unknown().optional(),
});

/** What a chore is made of (POST /chores, the assistant). */
export interface ChoreInput {
  title: string;
  note?: string;
  assigneeId?: string | null;
  day: string;
  time?: string | null;
  rrule?: string | null;
}

interface Fields {
  title: string;
  note: string;
  assigneeUserId: string | null;
  assigneePersonId: string | null;
  day: string;
  time: string | null;
  rrule: string | null;
}

/** Who can be assigned: the family's accounts and members without one, by name. */
export function chorePeople(db: Db, familyId: string): ChorePerson[] {
  return familyNames(db, familyId).map(({ id, name, account }) => ({ id, name, account }));
}

/** The assignee's columns for `assigneeId`: an account of the family or a person of it; 400
 *  for anyone else. */
function assigneeColumns(db: Db, familyId: string, assigneeId: string | null | undefined) {
  if (!assigneeId) return { assigneeUserId: null, assigneePersonId: null };
  const p = chorePeople(db, familyId).find((x) => x.id === assigneeId);
  if (!p) throw new HttpError(400, "assigneeId must be a member of the family");
  return p.account ? { assigneeUserId: p.id, assigneePersonId: null } : { assigneeUserId: null, assigneePersonId: p.id };
}

function cleanRrule(v: unknown): string | null {
  return v === undefined || v === null || v === "" ? null : normalizeRrule(v);
}

/** The body's fields over the stored ones (none on a POST); the assignee is only checked when
 *  the body names one. */
function cleanFields(db: Db, familyId: string, body: Record<string, unknown>, base?: ChoreRow): Fields {
  const merged: Record<string, unknown> = base
    ? { title: base.title, note: base.note, day: base.day, time: base.time, rrule: base.rrule }
    : {};
  for (const key of ["title", "note", "day", "time", "rrule", "assigneeId"]) if (key in body) merged[key] = body[key];
  const c = inputSchema.parse(merged);
  const assignee =
    base && !("assigneeId" in body)
      ? { assigneeUserId: base.assigneeUserId, assigneePersonId: base.assigneePersonId }
      : assigneeColumns(db, familyId, c.assigneeId);
  return { title: c.title, note: c.note, day: c.day, time: c.time ?? null, rrule: cleanRrule(c.rrule), ...assignee };
}

/** How far ahead a repeating chore's next time is looked for (a rule that seldom or never
 *  matches stays cheap). */
const NEXT_YEARS = 100;

/** The chore's next due day (see Chore.next). */
export function nextDue(row: Pick<ChoreRow, "day" | "rrule" | "doneAt">, today: string): string | null {
  if (!row.rrule) return row.doneAt ? null : row.day;
  const from = row.day > today ? row.day : today;
  return expandRule(parseRrule(row.rrule), row.day, from, addDays(from, NEXT_YEARS * 366), 1)[0] ?? null;
}

/** How far back a repeating chore's last occurrence before today is looked for. */
const PREVIOUS_DAYS = 400;

/** The occurrences around today (see Chore.occurrences). */
export function occurrencesAround(row: Pick<ChoreRow, "day" | "rrule">, today: string): string[] {
  if (!row.rrule) return [];
  const rule = parseRrule(row.rrule);
  const before = expandRule(rule, row.day, addDays(today, -PREVIOUS_DAYS), addDays(today, -1));
  const from = row.day > today ? row.day : today;
  const after = expandRule(rule, row.day, from, addDays(from, NEXT_YEARS * 366), 2);
  return [...before.slice(-1), ...(after[0] === today ? after : after.slice(0, 1))];
}

function choreJson(row: ChoreRow, who: ChorePerson[], today: string): Chore {
  const assigneeId = row.assigneeUserId ?? row.assigneePersonId;
  return {
    id: row.id,
    title: row.title,
    note: row.note,
    assignee: (assigneeId && who.find((p) => p.id === assigneeId)) || null,
    day: row.day,
    time: row.time,
    rrule: row.rrule,
    done: !row.rrule && !!row.doneAt,
    doneAt: !row.rrule && row.doneAt ? row.doneAt.toISOString() : null,
    next: nextDue(row, today),
    occurrences: occurrencesAround(row, today),
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

/** The family's chores by `next` (those without one last), then title. */
export function listChores(db: Db, familyId: string, today: string): Chore[] {
  const who = chorePeople(db, familyId);
  return db
    .select()
    .from(chores)
    .where(eq(chores.familyId, familyId))
    .all()
    .map((r) => choreJson(r, who, today))
    .sort(
      (a, b) =>
        (a.next === null ? 1 : 0) - (b.next === null ? 1 : 0) ||
        (a.next ?? "").localeCompare(b.next ?? "") ||
        a.title.localeCompare(b.title) ||
        a.id.localeCompare(b.id),
    );
}

export function getChoreRow(db: Db, familyId: string, id: string): ChoreRow | null {
  return db
    .select()
    .from(chores)
    .where(and(eq(chores.familyId, familyId), eq(chores.id, id)))
    .get() ?? null;
}

function requireChore(db: Db, familyId: string, id: string): ChoreRow {
  const row = getChoreRow(db, familyId, id);
  if (!row) throw new HttpError(404, "Chore not found");
  return row;
}

export function getChore(db: Db, familyId: string, id: string, today: string): Chore {
  return choreJson(requireChore(db, familyId, id), chorePeople(db, familyId), today);
}

/** Adds a chore. `body.id` (a chore put back, e.g. the assistant's undo) keeps that id; 409 if
 *  it is taken. */
export function createChore(
  db: Db,
  familyId: string,
  body: Record<string, unknown>,
  meta: { createdById?: string | null },
  now: Date,
  today: string,
): Chore {
  const fields = cleanFields(db, familyId, body);
  let id: string = randomUUID();
  if (body.id !== undefined && body.id !== null) {
    if (typeof body.id !== "string" || !ID_RE.test(body.id)) throw new HttpError(400, "id must be a chore id");
    if (db.select({ id: chores.id }).from(chores).where(eq(chores.id, body.id)).get()) {
      throw new HttpError(409, "There is already a chore with this id");
    }
    id = body.id;
  }
  db.insert(chores)
    .values({ id, familyId, ...fields, createdById: meta.createdById ?? null, createdAt: now, updatedAt: now })
    .run();
  return getChore(db, familyId, id, today);
}

/** Changes the fields the body has; a chore that starts repeating is no longer done. */
export function updateChore(db: Db, familyId: string, id: string, body: Record<string, unknown>, now: Date, today: string): Chore {
  const row = requireChore(db, familyId, id);
  const fields = cleanFields(db, familyId, body, row);
  db.update(chores)
    .set({ ...fields, ...(fields.rrule ? { doneAt: null } : {}), updatedAt: now })
    .where(and(eq(chores.familyId, familyId), eq(chores.id, id)))
    .run();
  return getChore(db, familyId, id, today);
}

/** Deletes a chore; 404 if the family has no such chore. */
export function deleteChore(db: Db, familyId: string, id: string): void {
  const res = db.delete(chores).where(and(eq(chores.familyId, familyId), eq(chores.id, id))).run();
  if (res.changes === 0) throw new HttpError(404, "Chore not found");
}

/** Marks a single chore done (keeping when it was first done) or open again; 400 for a
 *  repeating one. `updatedAt` stays: it is about edits. */
export function setChoreDone(db: Db, familyId: string, id: string, done: boolean, now: Date, today: string): Chore {
  const row = requireChore(db, familyId, id);
  if (row.rrule) throw new HttpError(400, "A repeating chore can't be marked done");
  db.update(chores)
    .set({ doneAt: done ? (row.doneAt ?? now) : null })
    .where(and(eq(chores.familyId, familyId), eq(chores.id, id)))
    .run();
  return getChore(db, familyId, id, today);
}

/** The chore's fields as a POST /chores or PATCH body that puts them back (the assistant's
 *  undo; a removed chore comes back with its `id` added). */
export function choreBody(row: ChoreRow): Record<string, unknown> {
  return {
    title: row.title,
    note: row.note,
    assigneeId: row.assigneeUserId ?? row.assigneePersonId,
    day: row.day,
    time: row.time,
    rrule: row.rrule,
  };
}
