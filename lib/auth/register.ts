import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { users } from "@/lib/db/schema";
import { acceptInvite, validateInvite } from "@/lib/families/invites";
import { AuthError } from "./errors";
import { hashPassword, validatePassword } from "./password";
import type { User } from "./tokens";

export function assertEmailFree(db: Db, email: string): void {
  if (db.select({ id: users.id }).from(users).where(eq(users.email, email)).get()) {
    throw new AuthError(409, "A user with this email already exists.");
  }
}

/** Creates an account from an invite link (password path) and joins the invite's family. */
export async function registerWithPassword(
  db: Db,
  args: { email: string; name: string; password: string; inviteCode: string },
  now: Date,
): Promise<User> {
  validateInvite(db, args.inviteCode, now);
  assertEmailFree(db, args.email);
  validatePassword(args.password, { email: args.email });
  const hash = await hashPassword(args.password);

  return db.transaction((tx) => {
    const user = tx
      .insert(users)
      .values({
        id: randomUUID(),
        email: args.email,
        name: args.name,
        password: hash,
        onboardingStep: "ADD_PASSKEY",
        createdAt: now,
      })
      .returning()
      .get();
    const { familyId } = acceptInvite(tx, user.id, args.inviteCode, now);
    return { ...user, lastFamilyId: familyId };
  });
}
