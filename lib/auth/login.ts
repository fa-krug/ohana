import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { users } from "@/lib/db/schema";
import { AuthError } from "./errors";
import { hashPassword, isLegacyHash, verifyPassword } from "./password";
import { assertNotLimited, recordFailure } from "./rate-limit";
import type { User } from "./tokens";

export async function loginWithPassword(
  db: Db,
  args: { email: string; password: string },
  now: Date,
): Promise<User> {
  const key = `login:${args.email}`;
  assertNotLimited(db, key, now);
  const user = db.select().from(users).where(eq(users.email, args.email)).get();
  if (!user || !(await verifyPassword(user.password, args.password))) {
    recordFailure(db, key, now);
    throw new AuthError(401, "Invalid email or password.");
  }
  if (isLegacyHash(user.password)) {
    const password = await hashPassword(args.password);
    db.update(users).set({ password }).where(eq(users.id, user.id)).run();
    return { ...user, password };
  }
  return user;
}
