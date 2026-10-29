import { randomUUID } from "node:crypto";
import { and, asc, eq, sql } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { familyMembers, passkeyCredentials, users } from "@/lib/db/schema";
import { AuthError } from "@/lib/auth/errors";
import { hasUsablePassword } from "@/lib/auth/password";
import { assertEmailFree } from "@/lib/auth/register";
import { issueSetupLink } from "@/lib/auth/setup-link";
import { deleteUserTokens } from "@/lib/auth/tokens";

export interface AdminUserDto {
  id: string;
  email: string;
  name: string;
  isAdmin: boolean;
  hasPassword: boolean;
  passkeyCount: number;
  familyCount: number;
  onboardingStep: string;
  createdAt: Date;
}

export function listUsers(db: Db): AdminUserDto[] {
  const passkeys = db
    .select({ userId: passkeyCredentials.userId, passkeyCount: sql<number>`count(*)`.as("passkey_count") })
    .from(passkeyCredentials)
    .groupBy(passkeyCredentials.userId)
    .as("passkeys");
  const memberships = db
    .select({ userId: familyMembers.userId, familyCount: sql<number>`count(*)`.as("family_count") })
    .from(familyMembers)
    .groupBy(familyMembers.userId)
    .as("memberships");
  return db
    .select({ user: users, passkeyCount: passkeys.passkeyCount, familyCount: memberships.familyCount })
    .from(users)
    .leftJoin(passkeys, eq(passkeys.userId, users.id))
    .leftJoin(memberships, eq(memberships.userId, users.id))
    .orderBy(asc(users.email))
    .all()
    .map(({ user, passkeyCount, familyCount }) => ({
      id: user.id,
      email: user.email,
      name: user.name,
      isAdmin: user.isAdmin,
      hasPassword: hasUsablePassword(user.password),
      passkeyCount: passkeyCount ?? 0,
      familyCount: familyCount ?? 0,
      onboardingStep: user.onboardingStep,
      createdAt: user.createdAt,
    }));
}

/** Creates an account without credentials and returns its setup link. */
export function createUser(
  db: Db,
  args: { email: string; name: string; isAdmin: boolean },
  now: Date,
): { userId: string; setupUrl: string; expiresAt: Date } {
  const email = args.email.trim().toLowerCase();
  if (!email) throw new AuthError(400, "An email is required.");
  assertEmailFree(db, email);
  const userId = randomUUID();
  db.insert(users)
    .values({
      id: userId,
      email,
      name: args.name.trim(),
      isAdmin: args.isAdmin,
      onboardingStep: "SET_CREDENTIALS",
      createdAt: now,
    })
    .run();
  const link = issueSetupLink(db, userId, now);
  return { userId, setupUrl: link.url, expiresAt: link.expiresAt };
}

export function updateUser(
  db: Db,
  actorId: string,
  userId: string,
  args: { email?: string; name?: string; isAdmin?: boolean },
): void {
  const user = db.select().from(users).where(eq(users.id, userId)).get();
  if (!user) throw new AuthError(404, "User not found.");
  const patch: Partial<typeof users.$inferInsert> = {};
  if (args.email !== undefined) {
    const email = args.email.trim().toLowerCase();
    if (!email) throw new AuthError(400, "An email is required.");
    if (email !== user.email) assertEmailFree(db, email);
    patch.email = email;
  }
  if (args.name !== undefined) patch.name = args.name.trim();
  if (args.isAdmin !== undefined && args.isAdmin !== user.isAdmin) {
    if (!args.isAdmin && userId === actorId) {
      throw new AuthError(400, "You can't remove your own administrator rights.");
    }
    patch.isAdmin = args.isAdmin;
  }
  if (Object.keys(patch).length > 0) db.update(users).set(patch).where(eq(users.id, userId)).run();
}

/** Deletes an account. Families keep going; one left without an editor gets its oldest
 *  member as editor (a family with no members left is deleted with it). */
export function deleteUser(db: Db, actorId: string, userId: string): void {
  if (userId === actorId) throw new AuthError(400, "You can't delete your own account.");
  const user = db.select().from(users).where(eq(users.id, userId)).get();
  if (!user) throw new AuthError(404, "User not found.");
  db.transaction((tx) => {
    const familyIds = tx
      .select({ familyId: familyMembers.familyId })
      .from(familyMembers)
      .where(eq(familyMembers.userId, userId))
      .all()
      .map((m) => m.familyId);
    tx.delete(users).where(eq(users.id, userId)).run(); // cascades tokens, passkeys, memberships
    for (const familyId of familyIds) promoteIfNoEditor(tx, familyId);
  });
}

function promoteIfNoEditor(db: Db, familyId: string): void {
  const members = db
    .select()
    .from(familyMembers)
    .where(eq(familyMembers.familyId, familyId))
    .orderBy(asc(familyMembers.joinedAt))
    .all();
  if (members.length === 0 || members.some((m) => m.role === "editor")) return;
  db.update(familyMembers)
    .set({ role: "editor" })
    .where(and(eq(familyMembers.familyId, familyId), eq(familyMembers.userId, members[0].userId)))
    .run();
}

/** A new setup link, e.g. for a forgotten password; signs the user out everywhere. */
export function resetUser(db: Db, userId: string, now: Date): { setupUrl: string; expiresAt: Date } {
  const link = issueSetupLink(db, userId, now);
  deleteUserTokens(db, userId, "session");
  return { setupUrl: link.url, expiresAt: link.expiresAt };
}
