// The family's chores: once (due on a day) or repeating (an RRULE, as calendar events have),
// assigned to one person of the family (an account or a member without one) or to nobody, in a
// part of the day (morning, day, evening; from the time when there is one, by the family's
// day parts: lib/chores/day-parts.ts). The server stores
// them, works out what is due next (`next`) and lists them by day (`choreAgenda`). A single
// chore is done as a whole, a repeating one per occurrence (`chore_completions`). Accounts
// subscribe to a chore to get a push notification when it is due (lib/chores/notify.ts).

import { randomUUID } from "node:crypto";
import { and, eq, gte, inArray, lte } from "drizzle-orm";
import { z } from "zod";
import type { Db } from "@/lib/db";
import { choreCompletions, choreNotified, choreSubscribers, chores } from "@/lib/db/schema";
import { HttpError } from "@/lib/api/http";
import { addDays, dateRange, diffDays, isValidDate } from "@/lib/calendar/dates";
import { expandRule, isRuleOccurrence, normalizeRrule, parseRrule } from "@/lib/calendar/rrule";
import { familyNames } from "@/lib/families/people";
import { PARTS, type Part, getDayParts, partOfTime } from "./day-parts";

export type ChoreRow = typeof chores.$inferSelect;

export { PARTS, type Part, partOfTime } from "./day-parts";

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
  part: Part;
  rrule: string | null;
  /** Single chores only; always false when repeating. */
  done: boolean;
  doneAt: string | null;
  /** Who ticked a single chore off (while they are in the family). */
  doneBy: ChorePerson | null;
  /** Single: `day` while open (also when past), null when done; repeating: the first
   *  occurrence on or after today, null once the series ended. */
  next: string | null;
  /** The accounts that get a notification when it is due. */
  subscriberIds: string[];
  /** The caller is among them. */
  subscribed: boolean;
  createdAt: string;
  /** Edits only, not done. */
  updatedAt: string;
}

/** One chore on one day (the agenda): a single chore on its day, a repeating one's occurrence. */
export interface ChoreItem {
  choreId: string;
  day: string;
  title: string;
  note: string;
  assignee: ChorePerson | null;
  part: Part;
  time: string | null;
  repeating: boolean;
  done: boolean;
  doneAt: string | null;
  doneBy: ChorePerson | null;
  subscribed: boolean;
}

const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
/** Ids a restored chore (the assistant's undo) may bring along (not the routes' own words). */
const ID_RE = /^[A-Za-z0-9-]{1,64}$/;
const RESERVED_IDS = new Set(["agenda", "day-parts"]);

/** A chore's fields as POST /chores takes them (PATCH: merged into the stored ones first). */
const inputSchema = z.object({
  title: z.string().trim().min(1, "title is required").max(200, "title is too long (max. 200)"),
  note: z.string().trim().max(2000, "note is too long (max. 2000)").optional().default(""),
  assigneeId: z.string().nullish(),
  day: z.string().refine(isValidDate, "day must be YYYY-MM-DD"),
  time: z.string().regex(TIME_RE, "time must be HH:MM").nullish(),
  part: z.enum(PARTS, { message: "part must be morning, day or evening" }).nullish(),
  rrule: z.unknown().optional(),
});

const subscribersSchema = z.array(z.string(), { message: "subscriberIds must be a list of ids" }).max(100);

/** What a chore is made of (POST /chores, the assistant). */
export interface ChoreInput {
  title: string;
  note?: string;
  assigneeId?: string | null;
  day: string;
  time?: string | null;
  part?: Part;
  rrule?: string | null;
  subscriberIds?: string[];
}

interface Fields {
  title: string;
  note: string;
  assigneeUserId: string | null;
  assigneePersonId: string | null;
  day: string;
  time: string | null;
  part: Part;
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
 *  the body names one. A time decides the part; without one the body's part, else the stored
 *  one, else "day". */
function cleanFields(db: Db, familyId: string, body: Record<string, unknown>, base?: ChoreRow): Fields {
  const merged: Record<string, unknown> = base
    ? { title: base.title, note: base.note, day: base.day, time: base.time, rrule: base.rrule }
    : {};
  for (const key of ["title", "note", "day", "time", "part", "rrule", "assigneeId"]) if (key in body) merged[key] = body[key];
  const c = inputSchema.parse(merged);
  const assignee =
    base && !("assigneeId" in body)
      ? { assigneeUserId: base.assigneeUserId, assigneePersonId: base.assigneePersonId }
      : assigneeColumns(db, familyId, c.assigneeId);
  const time = c.time ?? null;
  const part: Part = time ? partOfTime(time, getDayParts(db, familyId)) : (c.part ?? (base?.part as Part | undefined) ?? "day");
  return { title: c.title, note: c.note, day: c.day, time, part, rrule: cleanRrule(c.rrule), ...assignee };
}

/** `subscriberIds` checked: accounts of the family (400 for anyone else), each once. */
function cleanSubscribers(db: Db, familyId: string, v: unknown): string[] {
  const ids = [...new Set(subscribersSchema.parse(v))];
  const accounts = new Set(chorePeople(db, familyId).filter((p) => p.account).map((p) => p.id));
  if (ids.some((id) => !accounts.has(id))) throw new HttpError(400, "subscriberIds must be accounts of the family");
  return ids;
}

type Tx = Parameters<Parameters<Db["transaction"]>[0]>[0];

function setSubscribers(db: Db | Tx, choreId: string, ids: string[]): void {
  db.delete(choreSubscribers).where(eq(choreSubscribers.choreId, choreId)).run();
  if (ids.length) db.insert(choreSubscribers).values(ids.map((userId) => ({ choreId, userId }))).run();
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

/** The days a chore is due on from `from` to `to`: a single chore's day, a repeating one's
 *  occurrences. */
export function choreDays(row: Pick<ChoreRow, "day" | "rrule">, from: string, to: string): string[] {
  if (!row.rrule) return row.day >= from && row.day <= to ? [row.day] : [];
  return expandRule(parseRrule(row.rrule), row.day, from, to);
}

/** Whether `day` is one of a repeating chore's occurrences. */
export function isOccurrence(row: Pick<ChoreRow, "day" | "rrule">, day: string): boolean {
  return !!row.rrule && day >= row.day && isRuleOccurrence(parseRrule(row.rrule), row.day, day);
}

/** Who subscribed to each of the chores, in the order of `people` (accounts of the family). */
function subscribersOf(db: Db, ids: string[], people: ChorePerson[]): Map<string, string[]> {
  const out = new Map<string, string[]>();
  if (!ids.length) return out;
  const rank = new Map(people.map((p, i) => [p.id, i]));
  for (const r of db.select().from(choreSubscribers).where(inArray(choreSubscribers.choreId, ids)).all()) {
    if (rank.has(r.userId)) out.set(r.choreId, [...(out.get(r.choreId) ?? []), r.userId]);
  }
  for (const list of out.values()) list.sort((a, b) => rank.get(a)! - rank.get(b)!);
  return out;
}

const personOf = (who: ChorePerson[], id: string | null) => (id && who.find((p) => p.id === id)) || null;

function choreJson(row: ChoreRow, who: ChorePerson[], subscribers: string[], userId: string | null, today: string): Chore {
  const single = !row.rrule;
  return {
    id: row.id,
    title: row.title,
    note: row.note,
    assignee: personOf(who, row.assigneeUserId ?? row.assigneePersonId),
    day: row.day,
    time: row.time,
    part: row.part as Part,
    rrule: row.rrule,
    done: single && !!row.doneAt,
    doneAt: single && row.doneAt ? row.doneAt.toISOString() : null,
    doneBy: single && row.doneAt ? personOf(who, row.doneById) : null,
    next: nextDue(row, today),
    subscriberIds: subscribers,
    subscribed: !!userId && subscribers.includes(userId),
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

function choresJson(db: Db, familyId: string, rows: ChoreRow[], userId: string | null, today: string): Chore[] {
  const who = chorePeople(db, familyId);
  const subs = subscribersOf(db, rows.map((r) => r.id), who);
  return rows.map((r) => choreJson(r, who, subs.get(r.id) ?? [], userId, today));
}

/** The family's chores by `next` (those without one last), then title. `userId`: the caller
 *  (`subscribed`). */
export function listChores(db: Db, familyId: string, today: string, userId: string | null = null): Chore[] {
  const rows = db.select().from(chores).where(eq(chores.familyId, familyId)).all();
  return choresJson(db, familyId, rows, userId, today).sort(
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

export function getChore(db: Db, familyId: string, id: string, today: string, userId: string | null = null): Chore {
  return choresJson(db, familyId, [requireChore(db, familyId, id)], userId, today)[0];
}

/** The accounts subscribed to a chore. */
export function choreSubscriberIds(db: Db, choreId: string): string[] {
  return db
    .select({ userId: choreSubscribers.userId })
    .from(choreSubscribers)
    .where(eq(choreSubscribers.choreId, choreId))
    .all()
    .map((r) => r.userId);
}

/** Adds a chore, subscribed by `subscriberIds` (omitted: the creator). `body.id` (a chore put
 *  back, e.g. the assistant's undo) keeps that id; 409 if it is taken. */
export function createChore(
  db: Db,
  familyId: string,
  body: Record<string, unknown>,
  meta: { createdById?: string | null },
  now: Date,
  today: string,
): Chore {
  const fields = cleanFields(db, familyId, body);
  const subscribers =
    body.subscriberIds !== undefined
      ? cleanSubscribers(db, familyId, body.subscriberIds)
      : meta.createdById && chorePeople(db, familyId).some((p) => p.account && p.id === meta.createdById)
        ? [meta.createdById]
        : [];
  let id: string = randomUUID();
  if (body.id !== undefined && body.id !== null) {
    if (typeof body.id !== "string" || !ID_RE.test(body.id) || RESERVED_IDS.has(body.id)) throw new HttpError(400, "id must be a chore id");
    if (db.select({ id: chores.id }).from(chores).where(eq(chores.id, body.id)).get()) {
      throw new HttpError(409, "There is already a chore with this id");
    }
    id = body.id;
  }
  db.transaction((tx) => {
    tx.insert(chores)
      .values({ id, familyId, ...fields, createdById: meta.createdById ?? null, createdAt: now, updatedAt: now })
      .run();
    setSubscribers(tx, id, subscribers);
  });
  return getChore(db, familyId, id, today, meta.createdById ?? null);
}

/** Changes the fields the body has (and the subscribers with `subscriberIds`). A chore that
 *  starts repeating is no longer done; the completions of one that stops repeating stay (they
 *  count again when it repeats again, e.g. an undo); a new schedule may notify again. */
export function updateChore(
  db: Db,
  familyId: string,
  id: string,
  body: Record<string, unknown>,
  now: Date,
  today: string,
  userId: string | null = null,
): Chore {
  const row = requireChore(db, familyId, id);
  const fields = cleanFields(db, familyId, body, row);
  const subscribers = body.subscriberIds !== undefined ? cleanSubscribers(db, familyId, body.subscriberIds) : null;
  const rescheduled =
    fields.day !== row.day || fields.time !== row.time || fields.part !== row.part || fields.rrule !== row.rrule;
  db.transaction((tx) => {
    tx.update(chores)
      .set({ ...fields, ...(fields.rrule ? { doneAt: null, doneById: null } : {}), updatedAt: now })
      .where(and(eq(chores.familyId, familyId), eq(chores.id, id)))
      .run();
    if (rescheduled) tx.delete(choreNotified).where(eq(choreNotified.choreId, id)).run();
    if (subscribers) setSubscribers(tx, id, subscribers);
  });
  return getChore(db, familyId, id, today, userId);
}

/** Deletes a chore; 404 if the family has no such chore. */
export function deleteChore(db: Db, familyId: string, id: string): void {
  const res = db.delete(chores).where(and(eq(chores.familyId, familyId), eq(chores.id, id))).run();
  if (res.changes === 0) throw new HttpError(404, "Chore not found");
}

/** Marks a single chore done (keeping when and by whom it was first done) or open again; a
 *  repeating one's occurrence `day` (400 without one or for a day that isn't one). `updatedAt`
 *  stays: it is about edits. */
export function setChoreDone(
  db: Db,
  familyId: string,
  id: string,
  done: boolean,
  opts: { day?: unknown; userId: string | null },
  now: Date,
  today: string,
): Chore {
  const row = requireChore(db, familyId, id);
  if (!row.rrule) {
    db.update(chores)
      .set(done ? { doneAt: row.doneAt ?? now, doneById: row.doneAt ? row.doneById : opts.userId } : { doneAt: null, doneById: null })
      .where(and(eq(chores.familyId, familyId), eq(chores.id, id)))
      .run();
  } else {
    const day = opts.day;
    if (!isValidDate(day)) throw new HttpError(400, "day must be YYYY-MM-DD: the occurrence of a repeating chore");
    if (!isOccurrence(row, day)) throw new HttpError(400, "day isn't an occurrence of this chore");
    if (done) {
      db.insert(choreCompletions)
        .values({ choreId: id, day, doneById: opts.userId, doneAt: now })
        .onConflictDoNothing()
        .run();
    } else {
      db.delete(choreCompletions).where(and(eq(choreCompletions.choreId, id), eq(choreCompletions.day, day))).run();
    }
  }
  return getChore(db, familyId, id, today, opts.userId);
}

/** Whether a repeating chore's occurrence was ticked off. */
export function occurrenceDone(db: Db, choreId: string, day: string): boolean {
  return !!db
    .select({ day: choreCompletions.day })
    .from(choreCompletions)
    .where(and(eq(choreCompletions.choreId, choreId), eq(choreCompletions.day, day)))
    .get();
}

/** The occurrences ticked off from `from` to `to` per chore, ascending. */
export function completedDays(db: Db, choreIds: string[], from: string, to: string): Map<string, string[]> {
  const out = new Map<string, string[]>();
  if (!choreIds.length) return out;
  const rows = db
    .select({ choreId: choreCompletions.choreId, day: choreCompletions.day })
    .from(choreCompletions)
    .where(and(inArray(choreCompletions.choreId, choreIds), gte(choreCompletions.day, from), lte(choreCompletions.day, to)))
    .orderBy(choreCompletions.day)
    .all();
  for (const r of rows) out.set(r.choreId, [...(out.get(r.choreId) ?? []), r.day]);
  return out;
}

/** Subscribes the caller to a chore's notification or not. */
export function setChoreSubscribed(db: Db, familyId: string, id: string, userId: string, subscribed: boolean, today: string): Chore {
  requireChore(db, familyId, id);
  if (subscribed) db.insert(choreSubscribers).values({ choreId: id, userId }).onConflictDoNothing().run();
  else db.delete(choreSubscribers).where(and(eq(choreSubscribers.choreId, id), eq(choreSubscribers.userId, userId))).run();
  return getChore(db, familyId, id, today, userId);
}

/** At most this many days in one agenda. */
export const AGENDA_MAX_DAYS = 62;

const PART_RANK: Record<string, number> = { morning: 0, day: 1, evening: 2 };

/** Items by part, then time (none first), then title. */
function byPart(a: ChoreItem, b: ChoreItem): number {
  return (
    PART_RANK[a.part] - PART_RANK[b.part] ||
    (a.time === null ? 0 : 1) - (b.time === null ? 0 : 1) ||
    (a.time ?? "").localeCompare(b.time ?? "") ||
    a.title.localeCompare(b.title) ||
    a.choreId.localeCompare(b.choreId)
  );
}

/** The chores day by day from `from` to `to` (every day listed), and the open single chores
 *  from before `today` (overdue, oldest first). */
export function choreAgenda(
  db: Db,
  familyId: string,
  range: { from: string; to: string; today: string },
  userId: string | null,
): { days: { date: string; items: ChoreItem[] }[]; overdue: ChoreItem[] } {
  const { from, to, today } = range;
  if (to < from) throw new HttpError(400, "to must not be before from");
  if (diffDays(from, to) + 1 > AGENDA_MAX_DAYS) throw new HttpError(400, `At most ${AGENDA_MAX_DAYS} days at once`);
  const rows = db.select().from(chores).where(eq(chores.familyId, familyId)).all();
  const who = chorePeople(db, familyId);
  const subscribed = new Set(
    userId
      ? db
          .select({ choreId: choreSubscribers.choreId })
          .from(choreSubscribers)
          .where(eq(choreSubscribers.userId, userId))
          .all()
          .map((r) => r.choreId)
      : [],
  );
  const repeating = rows.filter((r) => r.rrule).map((r) => r.id);
  const completions = new Map<string, typeof choreCompletions.$inferSelect>();
  if (repeating.length) {
    for (const c of db
      .select()
      .from(choreCompletions)
      .where(and(inArray(choreCompletions.choreId, repeating), gte(choreCompletions.day, from), lte(choreCompletions.day, to)))
      .all()) {
      completions.set(`${c.choreId}@${c.day}`, c);
    }
  }
  const item = (row: ChoreRow, day: string): ChoreItem => {
    const done = row.rrule ? completions.get(`${row.id}@${day}`) : row.doneAt ? { doneAt: row.doneAt, doneById: row.doneById } : null;
    return {
      choreId: row.id,
      day,
      title: row.title,
      note: row.note,
      assignee: personOf(who, row.assigneeUserId ?? row.assigneePersonId),
      part: row.part as Part,
      time: row.time,
      repeating: !!row.rrule,
      done: !!done,
      doneAt: done ? done.doneAt.toISOString() : null,
      doneBy: done ? personOf(who, done.doneById) : null,
      subscribed: subscribed.has(row.id),
    };
  };
  const byDay = new Map(dateRange(from, to).map((d) => [d, [] as ChoreItem[]]));
  for (const row of rows) for (const day of choreDays(row, from, to)) byDay.get(day)?.push(item(row, day));
  const overdue = rows
    .filter((r) => !r.rrule && !r.doneAt && r.day < today)
    .map((r) => item(r, r.day))
    .sort((a, b) => a.day.localeCompare(b.day) || byPart(a, b));
  return { days: [...byDay].map(([date, items]) => ({ date, items: items.sort(byPart) })), overdue };
}

/** The chore's fields as a POST /chores or PATCH body that puts them back (the assistant's
 *  undo; a removed chore comes back with its `id` added). */
export function choreBody(row: ChoreRow, subscriberIds?: string[]): Record<string, unknown> {
  return {
    title: row.title,
    note: row.note,
    assigneeId: row.assigneeUserId ?? row.assigneePersonId,
    day: row.day,
    time: row.time,
    part: row.part,
    rrule: row.rrule,
    ...(subscriberIds ? { subscriberIds } : {}),
  };
}
