import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { users } from "@/lib/db/schema";
import { isLocale } from "@/lib/i18n/config";
import { AuthError } from "./errors";
import type { User } from "./tokens";

export function updateProfile(
  db: Db,
  userId: string,
  args: { name?: string; preferredLanguage?: string },
): User {
  const update: Partial<typeof users.$inferInsert> = {};
  if (args.name !== undefined) {
    const name = args.name.trim();
    if (name.length > 100) throw new AuthError(400, "The name is too long.");
    update.name = name;
  }
  if (args.preferredLanguage !== undefined) {
    if (!isLocale(args.preferredLanguage)) throw new AuthError(400, "Unsupported language.");
    update.preferredLanguage = args.preferredLanguage;
  }
  if (Object.keys(update).length === 0) {
    const user = db.select().from(users).where(eq(users.id, userId)).get();
    if (!user) throw new AuthError(404, "User not found.");
    return user;
  }
  const updated = db.update(users).set(update).where(eq(users.id, userId)).returning().get();
  if (!updated) throw new AuthError(404, "User not found.");
  return updated;
}
