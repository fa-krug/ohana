import { randomBytes, randomUUID } from "node:crypto";
import { and, eq, gt, isNull, lt } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { chores, families, familyMembers, familyPeople, invites, users } from "@/lib/db/schema";
import { AuthError } from "@/lib/auth/errors";
import { type Actor, type Role, getRole, isRole, requireRole } from "./roles";

export type Invite = typeof invites.$inferSelect;

export const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

/** A new invite link; with `personId` it is for that member without an account (their
 *  older open link stops working). */
export function createInvite(
  db: Db,
  actor: Actor,
  familyId: string,
  role: Role,
  now: Date,
  personId?: string,
): { code: string; expiresAt: Date } {
  requireRole(db, actor, familyId, "editor");
  if (personId) {
    const person = db
      .select({ id: familyPeople.id })
      .from(familyPeople)
      .where(and(eq(familyPeople.id, personId), eq(familyPeople.familyId, familyId)))
      .get();
    if (!person) throw new AuthError(404, "Member not found.");
    db.delete(invites).where(and(eq(invites.personId, personId), isNull(invites.usedById))).run();
  }
  const invite = db
    .insert(invites)
    .values({
      id: randomUUID(),
      familyId,
      createdById: actor.id,
      code: randomBytes(16).toString("base64url"),
      role,
      personId: personId ?? null,
      createdAt: now,
      expiresAt: new Date(now.getTime() + INVITE_TTL_MS),
    })
    .returning()
    .get();
  return { code: invite.code, expiresAt: invite.expiresAt };
}

/** Open invites of a family (not used, not expired), newest first. */
export function listInvites(db: Db, actor: Actor, familyId: string, now: Date): Invite[] {
  requireRole(db, actor, familyId, "editor");
  return db
    .select()
    .from(invites)
    .where(and(eq(invites.familyId, familyId), isNull(invites.usedById), gt(invites.expiresAt, now)))
    .all()
    .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
}

export function revokeInvite(db: Db, actor: Actor, familyId: string, inviteId: string): void {
  requireRole(db, actor, familyId, "editor");
  db.delete(invites).where(and(eq(invites.id, inviteId), eq(invites.familyId, familyId))).run();
}

export function validateInvite(db: Db, code: string, now: Date): Invite {
  const inv = db.select().from(invites).where(eq(invites.code, code)).get();
  if (!inv) throw new AuthError(400, "Invalid invite code.");
  if (inv.expiresAt.getTime() <= now.getTime()) throw new AuthError(400, "This invite has expired.");
  if (inv.usedById) throw new AuthError(400, "This invite has already been used.");
  return inv;
}

export function getInviteSummary(
  db: Db,
  code: string,
  now: Date,
): { familyName: string; personName: string | null; expiresAt: Date } {
  const inv = validateInvite(db, code, now);
  const family = db.select().from(families).where(eq(families.id, inv.familyId)).get();
  if (!family) throw new AuthError(400, "Invalid invite code.");
  return { familyName: family.name, personName: personOf(db, inv)?.name ?? null, expiresAt: inv.expiresAt };
}

function personOf(db: Db, inv: Invite) {
  if (!inv.personId) return null;
  return db.select().from(familyPeople).where(eq(familyPeople.id, inv.personId)).get() ?? null;
}

/** Makes `userId` a member with the invite's role and uses the invite up; an invite for a
 *  member without an account replaces that person (the membership takes their birthday and
 *  chores, an account without a name their name).
 *  Runs inside the caller's transaction when it registers a new account. */
export function acceptInvite(db: Db, userId: string, code: string, now: Date): { familyId: string } {
  const inv = validateInvite(db, code, now);
  if (getRole(db, inv.familyId, userId)) {
    throw new AuthError(400, "You are already a member of this family.");
  }
  const person = personOf(db, inv);
  db.insert(familyMembers)
    .values({
      familyId: inv.familyId,
      userId,
      role: isRole(inv.role) ? inv.role : "viewer",
      birthday: person?.birthday ?? null,
      joinedAt: now,
    })
    .run();
  db.update(invites).set({ usedById: userId, personId: null }).where(eq(invites.id, inv.id)).run();
  db.update(users).set({ lastFamilyId: inv.familyId }).where(eq(users.id, userId)).run();
  if (person) {
    db.update(users).set({ name: person.name }).where(and(eq(users.id, userId), eq(users.name, ""))).run();
    db.update(chores)
      .set({ assigneeUserId: userId, assigneePersonId: null })
      .where(and(eq(chores.familyId, inv.familyId), eq(chores.assigneePersonId, person.id)))
      .run();
    db.delete(familyPeople).where(eq(familyPeople.id, person.id)).run();
  }
  return { familyId: inv.familyId };
}

export function deleteExpiredInvites(db: Db, now: Date): number {
  return db.delete(invites).where(lt(invites.expiresAt, now)).run().changes;
}
