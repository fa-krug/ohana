import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { users } from "@/lib/db/schema";
import { AuthError } from "./errors";
import { getAppUrl } from "./config";
import { createToken, deleteToken, deleteUserTokens, findToken, type User } from "./tokens";

/** A new one-time setup link for a user (older ones stop working). It signs the person in
 *  and lets them add a passkey or set a password without knowing the old one. */
export function issueSetupLink(db: Db, userId: string, now: Date): { url: string; expiresAt: Date } {
  const user = db.select({ id: users.id }).from(users).where(eq(users.id, userId)).get();
  if (!user) throw new AuthError(404, "User not found.");
  deleteUserTokens(db, userId, "setup");
  const { token, row } = createToken(db, { userId, kind: "setup" }, now);
  return { url: `${getAppUrl()}/setup-link/${token}`, expiresAt: row.expiresAt! };
}

/** Uses up a setup link; the caller opens a session with `canReset` for the user. */
export function redeemSetupLink(db: Db, token: string, now: Date): User {
  const found = findToken(db, token, "setup", now);
  if (!found) throw new AuthError(400, "This setup link is invalid or has expired.");
  deleteToken(db, found.token.id);
  return found.user;
}
