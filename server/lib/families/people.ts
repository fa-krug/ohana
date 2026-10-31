import { randomUUID } from "node:crypto";
import { and, asc, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { familyMembers, familyPeople, users } from "@/lib/db/schema";
import { AuthError } from "@/lib/auth/errors";
import { addDays, formatDate, isValidDate } from "@/lib/calendar/dates";
import { createInvite } from "./invites";
import { type Actor, type Role, requireRole } from "./roles";

/** A family member without an account (a child, a grandparent). */
export interface PersonDto {
  id: string;
  name: string;
  birthday: string | null;
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

function peopleOf(db: Db, familyId: string): PersonDto[] {
  return db
    .select({ id: familyPeople.id, name: familyPeople.name, birthday: familyPeople.birthday, createdAt: familyPeople.createdAt })
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

/** Adds someone without an account; with `invite`, also an invite link for them that makes
 *  them a member with this role (and replaces them) once accepted. */
export function addPerson(
  db: Db,
  actor: Actor,
  familyId: string,
  args: { name: string; birthday?: string | null; invite?: Role | null },
  now: Date,
): { person: PersonDto; invite: { code: string; expiresAt: Date } | null } {
  requireRole(db, actor, familyId, "editor");
  const name = args.name.trim();
  const birthday = args.birthday ?? null;
  assertFreeName(db, familyId, name);
  assertBirthday(birthday, now);
  return db.transaction((tx) => {
    const person = tx
      .insert(familyPeople)
      .values({ id: randomUUID(), familyId, name, birthday, createdAt: now })
      .returning({ id: familyPeople.id, name: familyPeople.name, birthday: familyPeople.birthday, createdAt: familyPeople.createdAt })
      .get();
    const invite = args.invite ? createInvite(tx, actor, familyId, args.invite, now, person.id) : null;
    return { person, invite };
  });
}

/** Changes the name and the birthday of someone without an account. */
export function updatePerson(
  db: Db,
  actor: Actor,
  familyId: string,
  personId: string,
  args: { name: string; birthday: string | null },
  now: Date,
): void {
  requireRole(db, actor, familyId, "editor");
  assertPerson(db, familyId, personId);
  const name = args.name.trim();
  assertFreeName(db, familyId, name, personId);
  assertBirthday(args.birthday, now);
  db.update(familyPeople).set({ name, birthday: args.birthday }).where(eq(familyPeople.id, personId)).run();
}

/** Removes someone without an account (and their open invite). */
export function removePerson(db: Db, actor: Actor, familyId: string, personId: string): void {
  requireRole(db, actor, familyId, "editor");
  assertPerson(db, familyId, personId);
  db.delete(familyPeople).where(eq(familyPeople.id, personId)).run();
}

/** Everyone in the family by name, with and without an account, sorted: the choices for
 *  "who is it for" (a booked appointment, an event) and what the assistant knows. */
export function familyNames(
  db: Db,
  familyId: string,
): { id: string; name: string; account: boolean; birthday: string | null }[] {
  const accounts = db
    .select({ id: users.id, name: users.name, email: users.email, birthday: familyMembers.birthday })
    .from(familyMembers)
    .innerJoin(users, eq(users.id, familyMembers.userId))
    .where(eq(familyMembers.familyId, familyId))
    .all()
    .map((u) => ({ id: u.id, name: u.name.trim() || u.email.split("@")[0], account: true, birthday: u.birthday }));
  const people = peopleOf(db, familyId).map((p) => ({ id: p.id, name: p.name, account: false, birthday: p.birthday }));
  return [...accounts, ...people].sort((a, b) => a.name.localeCompare(b.name));
}
