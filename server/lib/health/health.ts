// Check-ups and vaccinations of the family's members (phase 13): the records in `health_records`,
// the state of each item worked out from the member's birthday (status.ts, schedule.ts).
//
// Who sees what: editors everyone, a viewer only themselves (and records only their own). The
// members are those of familyNames (accounts and people without one); no birthday, no items.

import { randomUUID } from "node:crypto";
import { and, eq, inArray, or } from "drizzle-orm";
import { HttpError } from "@/lib/api/http";
import { isValidDate } from "@/lib/calendar/dates";
import type { Db } from "@/lib/db";
import { healthRecords } from "@/lib/db/schema";
import { familyNames } from "@/lib/families/people";
import { type Lang, SCHEDULE_BY_CODE, applies } from "./schedule";
import { type HealthRecord, type PersonHealth, type RecordStatus, personHealth } from "./status";

export type Row = typeof healthRecords.$inferSelect;

export interface HealthMember {
  id: string;
  name: string;
  account: boolean;
  birthday: string | null;
  color: string;
  photo: string | null;
  /** The caller may record for them (editors: everyone, viewers: themselves). */
  canEdit: boolean;
}

export type MemberHealth = HealthMember & PersonHealth;

const dayOfDate = (d: Date) => d.toISOString().slice(0, 10);

export function toRecord(r: Row): HealthRecord {
  return {
    id: r.id,
    code: r.code,
    day: r.day,
    status: r.status === "skipped" ? "skipped" : "done",
    note: r.note,
    recorded: dayOfDate(r.createdAt),
  };
}

/** A record as the API answers it. */
export function recordOut(r: Row) {
  return {
    id: r.id,
    memberId: r.memberUserId ?? r.memberPersonId,
    code: r.code,
    day: r.day,
    status: r.status,
    note: r.note,
  };
}

const memberWhere = (familyId: string, memberId: string) =>
  and(
    eq(healthRecords.familyId, familyId),
    or(eq(healthRecords.memberUserId, memberId), eq(healthRecords.memberPersonId, memberId)),
  );

/** The family's members the caller may see: editors (`viewerId` null) all, a viewer themselves. */
export function healthMembers(db: Db, familyId: string, viewerId: string | null): HealthMember[] {
  return familyNames(db, familyId)
    .filter((m) => viewerId === null || m.id === viewerId)
    .map(({ id, name, account, birthday, color, photo }) => ({ id, name, account, birthday, color, photo, canEdit: true }));
}

/** One member the caller may see; 404 for anyone else. */
export function requireMember(db: Db, familyId: string, memberId: unknown, viewerId: string | null): HealthMember {
  if (typeof memberId !== "string" || !memberId) throw new HttpError(400, "memberId is required");
  const m = healthMembers(db, familyId, viewerId).find((x) => x.id === memberId);
  if (!m) throw new HttpError(404, "Member not found");
  return m;
}

export function recordsOf(db: Db, familyId: string, memberId: string): Row[] {
  return db.select().from(healthRecords).where(memberWhere(familyId, memberId)).all();
}

export function memberHealth(db: Db, familyId: string, member: HealthMember, today: string, lang: Lang): MemberHealth {
  const records = recordsOf(db, familyId, member.id).map(toRecord);
  return { ...member, ...personHealth(member.birthday, today, records, lang) };
}

/** Everyone the caller may see, with their items. */
export function listHealth(db: Db, familyId: string, viewerId: string | null, today: string, lang: Lang): MemberHealth[] {
  const members = healthMembers(db, familyId, viewerId);
  const all = members.length
    ? db.select().from(healthRecords).where(eq(healthRecords.familyId, familyId)).all()
    : [];
  return members.map((m) => {
    const records = all.filter((r) => (r.memberUserId ?? r.memberPersonId) === m.id).map(toRecord);
    return { ...m, ...personHealth(m.birthday, today, records, lang) };
  });
}

export interface RecordInput {
  id?: string;
  code: string;
  day: string | null;
  status: RecordStatus;
  note: string;
}

/** A record's input, checked: a code of the schedule, a day (or null) neither in the future nor
 *  before the member's birth. */
export function recordInput(raw: unknown, member: HealthMember, today: string): RecordInput {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new HttpError(400, "A record must be an object");
  const r = raw as Record<string, unknown>;
  const item = typeof r.code === "string" ? SCHEDULE_BY_CODE.get(r.code) : undefined;
  if (!item) throw new HttpError(400, `Unknown code "${String(r.code)}"`);
  const day = r.day === undefined || r.day === null || r.day === "" ? null : r.day;
  if (day !== null && !isValidDate(day)) throw new HttpError(400, "day must be YYYY-MM-DD or null");
  if (day !== null && day > today) throw new HttpError(400, "day can't be in the future");
  if (day !== null && member.birthday && day < member.birthday) throw new HttpError(400, "day can't be before the birthday");
  const status = r.status === undefined ? "done" : r.status;
  if (status !== "done" && status !== "skipped") throw new HttpError(400, "status must be done or skipped");
  const note = r.note === undefined || r.note === null ? "" : r.note;
  if (typeof note !== "string") throw new HttpError(400, "note must be a string");
  if (note.length > 200) throw new HttpError(400, "note is too long (max. 200)");
  const id = r.id === undefined ? undefined : r.id;
  if (id !== undefined && (typeof id !== "string" || !id || id.length > 64)) throw new HttpError(400, "id must be a string");
  return { id, code: item.code, day, status, note: note.trim() };
}

/** Whether a code is recorded once (a check-up, a visit) rather than each time (tetanus, flu). */
export const recordedOnce = (code: string) => {
  const item = SCHEDULE_BY_CODE.get(code);
  return !(item?.every || item?.seasonal);
};

/** Saves records for a member. A code recorded once replaces its earlier record (returned as
 *  `replaced`, for undo); a repeating one adds another, unless that day is already recorded.
 *  Runs in one transaction. */
export function addRecords(
  db: Db,
  familyId: string,
  member: HealthMember,
  inputs: RecordInput[],
  opts: { createdById: string | null; now: Date },
): { records: Row[]; replaced: Row[] } {
  const isUser = member.account;
  // One per code (a repeating one: per day); the last wins.
  const unique = new Map<string, RecordInput>();
  for (const i of inputs) unique.set(recordedOnce(i.code) ? i.code : `${i.code}:${i.day ?? ""}`, i);
  return db.transaction(
    (tx) => {
      const records: Row[] = [];
      const replaced: Row[] = [];
      for (const input of unique.values()) {
        const existing = tx
          .select()
          .from(healthRecords)
          .where(and(memberWhere(familyId, member.id), eq(healthRecords.code, input.code)))
          .all();
        const gone = recordedOnce(input.code)
          ? existing
          : existing.filter((r) => r.day !== null && r.day === input.day);
        if (input.id) {
          const taken = tx.select().from(healthRecords).where(eq(healthRecords.id, input.id)).get();
          if (taken && taken.familyId !== familyId) throw new HttpError(409, "That id is taken");
          if (taken && !gone.some((g) => g.id === taken.id)) gone.push(taken);
        }
        if (gone.length) {
          tx.delete(healthRecords).where(inArray(healthRecords.id, gone.map((g) => g.id))).run();
          replaced.push(...gone);
        }
        const row: Row = {
          id: input.id ?? randomUUID(),
          familyId,
          memberUserId: isUser ? member.id : null,
          memberPersonId: isUser ? null : member.id,
          code: input.code,
          day: input.day,
          status: input.status,
          note: input.note,
          createdById: opts.createdById,
          createdAt: opts.now,
          updatedAt: opts.now,
        };
        tx.insert(healthRecords).values(row).run();
        records.push(row);
      }
      return { records, replaced };
    },
    { behavior: "immediate" },
  );
}

/** A record of the family, if it belongs to a member the caller may see. */
export function getRecord(db: Db, familyId: string, id: string, viewerId: string | null): Row {
  const row = db
    .select()
    .from(healthRecords)
    .where(and(eq(healthRecords.familyId, familyId), eq(healthRecords.id, id)))
    .get();
  if (!row || (viewerId !== null && (row.memberUserId ?? row.memberPersonId) !== viewerId)) {
    throw new HttpError(404, "Record not found");
  }
  return row;
}

/** Changes a record's day, status or note. */
export function updateRecord(
  db: Db,
  familyId: string,
  id: string,
  raw: Record<string, unknown>,
  viewerId: string | null,
  today: string,
  now: Date,
): { record: Row; before: Row } {
  const before = getRecord(db, familyId, id, viewerId);
  const member = requireMember(db, familyId, before.memberUserId ?? before.memberPersonId, viewerId);
  const input = recordInput(
    {
      code: before.code,
      day: "day" in raw ? raw.day : before.day,
      status: raw.status ?? before.status,
      note: "note" in raw ? raw.note : before.note,
    },
    member,
    today,
  );
  db.update(healthRecords)
    .set({ day: input.day, status: input.status, note: input.note, updatedAt: now })
    .where(eq(healthRecords.id, id))
    .run();
  return { record: { ...before, day: input.day, status: input.status, note: input.note, updatedAt: now }, before };
}

export function deleteRecord(db: Db, familyId: string, id: string, viewerId: string | null): Row {
  const row = getRecord(db, familyId, id, viewerId);
  db.delete(healthRecords).where(eq(healthRecords.id, id)).run();
  return row;
}

/** Marks every child's item whose window closed without a record as done, date unknown ("all
 *  earlier ones were done"). */
export function markPastDone(
  db: Db,
  familyId: string,
  member: HealthMember,
  today: string,
  opts: { createdById: string | null; now: Date },
): Row[] {
  const { items } = memberHealth(db, familyId, member, today, "en");
  const past = items.filter((i) => i.status === "past");
  if (!past.length) return [];
  return addRecords(
    db,
    familyId,
    member,
    past.map((i) => ({ code: i.code, day: null, status: "done", note: "" })),
    opts,
  ).records;
}

/** Whether an item is one of the member's (by age), for the scanner's suggestions. */
export function codeApplies(code: string, birthday: string | null, today: string): boolean {
  const item = SCHEDULE_BY_CODE.get(code);
  return !!item && !!birthday && applies(item, birthday, today);
}
