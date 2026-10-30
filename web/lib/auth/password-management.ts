import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { authTokens, passkeyCredentials, users } from "@/lib/db/schema";
import { AuthError } from "./errors";
import { afterPassword, afterPasskey } from "./onboarding";
import { hashPassword, hasUsablePassword, validatePassword, verifyPassword } from "./password";
import { deleteUserTokens } from "./tokens";

function requireUser(db: Db, userId: string) {
  const user = db.select().from(users).where(eq(users.id, userId)).get();
  if (!user) throw new AuthError(404, "User not found.");
  return user;
}

/**
 * Sets or changes the password and signs out the user's other devices. The current
 * password is needed unless the session was opened with a setup link (`canReset`).
 */
export async function setPassword(
  db: Db,
  userId: string,
  args: { currentPassword?: string; newPassword: string },
  session: { id: string; canReset: boolean },
): Promise<void> {
  const user = requireUser(db, userId);
  if (hasUsablePassword(user.password) && !session.canReset) {
    if (!args.currentPassword || !(await verifyPassword(user.password, args.currentPassword))) {
      throw new AuthError(400, "Current password is incorrect.");
    }
  }
  validatePassword(args.newPassword, { email: user.email });
  db.update(users)
    .set({ password: await hashPassword(args.newPassword) })
    .where(eq(users.id, userId))
    .run();
  afterPassword(db, user);
  deleteUserTokens(db, userId, "session", session.id);
  // The setup link has done its job: from now on, the current password is needed again.
  if (session.canReset) {
    db.update(authTokens).set({ canReset: false }).where(eq(authTokens.id, session.id)).run();
  }
}

export async function removePassword(
  db: Db,
  userId: string,
  args: { currentPassword: string },
  session: { id: string },
): Promise<void> {
  const user = requireUser(db, userId);
  if (!hasUsablePassword(user.password)) {
    throw new AuthError(400, "No password is set.");
  }
  if (!(await verifyPassword(user.password, args.currentPassword))) {
    throw new AuthError(400, "Current password is incorrect.");
  }
  const passkey = db
    .select({ id: passkeyCredentials.id })
    .from(passkeyCredentials)
    .where(eq(passkeyCredentials.userId, userId))
    .get();
  if (!passkey) {
    throw new AuthError(400, "Cannot remove your password without a passkey set.");
  }
  db.update(users).set({ password: "" }).where(eq(users.id, userId)).run();
  deleteUserTokens(db, userId, "session", session.id);
}

export function skipPasskey(db: Db, userId: string): void {
  const user = requireUser(db, userId);
  if (user.onboardingStep === "ADD_PASSKEY") afterPasskey(db, user);
}
