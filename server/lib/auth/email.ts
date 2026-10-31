import { and, eq, ne } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { users } from "@/lib/db/schema";
import { AuthError } from "./errors";
import type { User } from "./tokens";

export function changeEmail(db: Db, userId: string, newEmail: string): User {
  const taken = db
    .select({ id: users.id })
    .from(users)
    .where(and(eq(users.email, newEmail), ne(users.id, userId)))
    .get();
  if (taken) throw new AuthError(409, "A user with this email already exists.");

  const updated = db
    .update(users)
    .set({ email: newEmail })
    .where(eq(users.id, userId))
    .returning()
    .get();
  if (!updated) throw new AuthError(404, "User not found.");
  return updated;
}
