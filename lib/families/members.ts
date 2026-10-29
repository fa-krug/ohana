import { and, asc, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { familyMembers, users } from "@/lib/db/schema";
import { AuthError } from "@/lib/auth/errors";
import { assertBirthday } from "./people";
import { type Actor, type Role, isRole, requireRole } from "./roles";

export interface MemberDto {
  userId: string;
  email: string;
  name: string;
  role: Role;
  birthday: string | null;
  joinedAt: Date;
}

export function listMembers(db: Db, actor: Actor, familyId: string): MemberDto[] {
  requireRole(db, actor, familyId, "viewer");
  return db
    .select({
      userId: familyMembers.userId,
      email: users.email,
      name: users.name,
      role: familyMembers.role,
      birthday: familyMembers.birthday,
      joinedAt: familyMembers.joinedAt,
    })
    .from(familyMembers)
    .innerJoin(users, eq(users.id, familyMembers.userId))
    .where(eq(familyMembers.familyId, familyId))
    .orderBy(asc(users.email))
    .all()
    .map((m) => ({ ...m, role: isRole(m.role) ? m.role : "viewer" }));
}

function memberRows(db: Db, familyId: string) {
  return db.select().from(familyMembers).where(eq(familyMembers.familyId, familyId)).all();
}

/** Throws unless, after `change`, the family still has an editor (or no members at all). */
function assertKeepsEditor(
  db: Db,
  familyId: string,
  change: { userId: string; role: Role | null },
): void {
  const after = memberRows(db, familyId)
    .map((m) => (m.userId === change.userId ? { ...m, role: change.role } : m))
    .filter((m) => m.role !== null);
  if (after.length > 0 && !after.some((m) => m.role === "editor")) {
    throw new AuthError(400, "A family needs at least one editor.");
  }
}

/** Adds the account with this sign-in name to the family. */
export function addMember(
  db: Db,
  actor: Actor,
  familyId: string,
  args: { email: string; role: Role },
  now: Date,
): MemberDto {
  requireRole(db, actor, familyId, "editor");
  const email = args.email.trim().toLowerCase();
  const user = db.select().from(users).where(eq(users.email, email)).get();
  if (!user) throw new AuthError(404, "There is no account with this email.");
  const existing = memberRows(db, familyId).find((m) => m.userId === user.id);
  if (existing) throw new AuthError(409, "This person is already a member.");
  db.insert(familyMembers).values({ familyId, userId: user.id, role: args.role, joinedAt: now }).run();
  if (!user.lastFamilyId) {
    db.update(users).set({ lastFamilyId: familyId }).where(eq(users.id, user.id)).run();
  }
  return { userId: user.id, email: user.email, name: user.name, role: args.role, birthday: null, joinedAt: now };
}

/** A member's birthday in this family; members set their own, editors anyone's. */
export function setMemberBirthday(
  db: Db,
  actor: Actor,
  familyId: string,
  userId: string,
  birthday: string | null,
  now: Date,
): void {
  requireRole(db, actor, familyId, userId === actor.id ? "viewer" : "editor");
  if (!memberRows(db, familyId).some((m) => m.userId === userId)) {
    throw new AuthError(404, "Member not found.");
  }
  assertBirthday(birthday, now);
  db.update(familyMembers)
    .set({ birthday })
    .where(and(eq(familyMembers.familyId, familyId), eq(familyMembers.userId, userId)))
    .run();
}

export function setRole(db: Db, actor: Actor, familyId: string, userId: string, role: Role): void {
  requireRole(db, actor, familyId, "editor");
  if (!memberRows(db, familyId).some((m) => m.userId === userId)) {
    throw new AuthError(404, "Member not found.");
  }
  assertKeepsEditor(db, familyId, { userId, role });
  db.update(familyMembers)
    .set({ role })
    .where(and(eq(familyMembers.familyId, familyId), eq(familyMembers.userId, userId)))
    .run();
}

/** Removes a member; everyone may remove themselves (leave), editors anyone. */
export function removeMember(db: Db, actor: Actor, familyId: string, userId: string): void {
  requireRole(db, actor, familyId, userId === actor.id ? "viewer" : "editor");
  const rows = memberRows(db, familyId);
  if (!rows.some((m) => m.userId === userId)) throw new AuthError(404, "Member not found.");
  if (rows.length === 1 && !actor.admin) {
    throw new AuthError(400, "You are the only member: delete the family instead.");
  }
  assertKeepsEditor(db, familyId, { userId, role: null });
  db.delete(familyMembers)
    .where(and(eq(familyMembers.familyId, familyId), eq(familyMembers.userId, userId)))
    .run();
  db.update(users)
    .set({ lastFamilyId: null })
    .where(and(eq(users.id, userId), eq(users.lastFamilyId, familyId)))
    .run();
}
