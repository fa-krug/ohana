import { randomUUID } from "node:crypto";
import { and, asc, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { familyMembers, familyPeople, users } from "@/lib/db/schema";
import { AuthError } from "@/lib/auth/errors";
import { addDays, formatDate, isValidDate } from "@/lib/calendar/dates";
import { createInvite } from "./invites";
import { assertMemberColor, nextMemberColor } from "./member-colors";
import { deletePhotoFile } from "./photos";
import { type Actor, type Role, requireRole } from "./roles";

/** A family member without an account (a child, a grandparent). */
export interface PersonDto {
  id: string;
  name: string;
  birthday: string | null;
  /** A key of MEMBER_COLORS. */
  color: string;
  /** Their photo's path under MEDIA_ROOT (served at /api/images/<photo>), or null. */
  photo: string | null;
  createdAt: Date;
}

/** Throws unless `birthday` is null or a real day, at the latest today (a day of slack for
 *  time zones ahead of UTC). */
export function assertBirthday(birthday: string | null, now: Date): void {
  if (birthday === null) return;
  if (!isValidDate(birthday) || birthday > addDays(formatDate(now), 1)) {
    throw new AuthError(400, "Invalid birthday.");
  }
}

export function listPeople(db: Db, actor: Actor, familyId: string): PersonDto[] {
  requireRole(db, actor, familyId, "viewer");
  return peopleOf(db, familyId);
}

const personColumns = {
  id: familyPeople.id,
  name: familyPeople.name,
  birthday: familyPeople.birthday,
  color: familyPeople.color,
  photo: familyPeople.photo,
  createdAt: familyPeople.createdAt,
};

function peopleOf(db: Db, familyId: string): PersonDto[] {
  return db
    .select(personColumns)
    .from(familyPeople)
    .where(eq(familyPeople.familyId, familyId))
    .orderBy(asc(familyPeople.name))
    .all();
}

function assertFreeName(db: Db, familyId: string, name: string, exceptId?: string): void {
  const key = name.toLocaleLowerCase();
  if (peopleOf(db, familyId).some((p) => p.id !== exceptId && p.name.toLocaleLowerCase() === key)) {
    throw new AuthError(409, "There is already someone with this name.");
  }
}

function assertPerson(db: Db, familyId: string, personId: string) {
  const row = db
    .select()
    .from(familyPeople)
    .where(and(eq(familyPeople.id, personId), eq(familyPeople.familyId, familyId)))
    .get();
  if (!row) throw new AuthError(404, "Member not found.");
  return row;
}

/** Adds someone without an account (in `color`, else one nobody has yet); with `invite`, also
 *  an invite link for them that makes them a member with this role (and replaces them) once
 *  accepted. */
export function addPerson(
  db: Db,
  actor: Actor,
  familyId: string,
  args: { name: string; birthday?: string | null; color?: string | null; invite?: Role | null },
  now: Date,
): { person: PersonDto; invite: { code: string; expiresAt: Date } | null } {
  requireRole(db, actor, familyId, "editor");
  const name = args.name.trim();
  const birthday = args.birthday ?? null;
  assertFreeName(db, familyId, name);
  assertBirthday(birthday, now);
  const color = args.color ?? nextMemberColor(db, familyId);
  assertMemberColor(color);
  return db.transaction((tx) => {
    const person = tx
      .insert(familyPeople)
      .values({ id: randomUUID(), familyId, name, birthday, color, createdAt: now })
      .returning(personColumns)
      .get();
    const invite = args.invite ? createInvite(tx, actor, familyId, args.invite, now, person.id) : null;
    return { person, invite };
  });
}

/** Changes the name, the birthday and (if given) the color of someone without an account;
 *  answers them as they are now. */
export function updatePerson(
  db: Db,
  actor: Actor,
  familyId: string,
  personId: string,
  args: { name: string; birthday: string | null; color?: string },
  now: Date,
): PersonDto {
  requireRole(db, actor, familyId, "editor");
  assertPerson(db, familyId, personId);
  const name = args.name.trim();
  assertFreeName(db, familyId, name, personId);
  assertBirthday(args.birthday, now);
  if (args.color !== undefined) assertMemberColor(args.color);
  return db
    .update(familyPeople)
    .set({ name, birthday: args.birthday, ...(args.color !== undefined ? { color: args.color } : {}) })
    .where(eq(familyPeople.id, personId))
    .returning(personColumns)
    .get()!;
}

/** Removes someone without an account (and their open invite and photo; their entry types
 *  become nobody's through the foreign key). */
export function removePerson(db: Db, actor: Actor, familyId: string, personId: string): void {
  requireRole(db, actor, familyId, "editor");
  const { photo } = assertPerson(db, familyId, personId);
  db.delete(familyPeople).where(eq(familyPeople.id, personId)).run();
  deletePhotoFile(photo);
}

/** Everyone in the family by name, with and without an account, sorted: the choices for
 *  "who is it for" (a booked appointment, an event) and what the assistant knows. */
export function familyNames(
  db: Db,
  familyId: string,
): { id: string; name: string; account: boolean; birthday: string | null; color: string; photo: string | null }[] {
  const accounts = db
    .select({
      id: users.id,
      name: users.name,
      email: users.email,
      birthday: familyMembers.birthday,
      color: familyMembers.color,
      photo: familyMembers.photo,
    })
    .from(familyMembers)
    .innerJoin(users, eq(users.id, familyMembers.userId))
    .where(eq(familyMembers.familyId, familyId))
    .all()
    .map((u) => ({
      id: u.id,
      name: u.name.trim() || u.email.split("@")[0],
      account: true,
      birthday: u.birthday,
      color: u.color,
      photo: u.photo,
    }));
  const people = peopleOf(db, familyId).map((p) => ({
    id: p.id,
    name: p.name,
    account: false,
    birthday: p.birthday,
    color: p.color,
    photo: p.photo,
  }));
  return [...accounts, ...people].sort((a, b) => a.name.localeCompare(b.name));
}
