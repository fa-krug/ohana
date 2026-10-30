import { randomUUID } from "node:crypto";
import type { Db } from "@/lib/db";
import { users } from "@/lib/db/schema";
import { AuthError } from "./errors";
import { hashPassword, validatePassword } from "./password";
import type { User } from "./tokens";

/** True iff at least one user row exists. Emptiness = fresh install → first-run available. */
export function hasAnyUser(db: Db): boolean {
  return db.select({ id: users.id }).from(users).limit(1).get() !== undefined;
}

/**
 * Create the very first user, an administrator (password path). Only succeeds while the
 * users table is empty; the emptiness check and insert run inside one synchronous
 * transaction so two concurrent setups cannot both create an admin. A passkey is offered
 * next (ADD_PASSKEY), then "/" asks for the first family.
 */
export async function registerFirstUser(
  db: Db,
  args: { email: string; name: string; password: string },
  now: Date,
): Promise<User> {
  validatePassword(args.password, { email: args.email });
  const hash = await hashPassword(args.password);
  return db.transaction((tx) => {
    if (hasAnyUser(tx)) {
      throw new AuthError(409, "Setup has already been completed.");
    }
    return tx
      .insert(users)
      .values({
        id: randomUUID(),
        email: args.email,
        name: args.name,
        password: hash,
        isAdmin: true,
        onboardingStep: "ADD_PASSKEY",
        createdAt: now,
      })
      .returning()
      .get();
  });
}
