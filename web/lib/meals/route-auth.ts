import { db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { getApiUser, getAuth } from "@/lib/auth/session";
import { type Role, requireRole } from "@/lib/families/roles";
import type { User } from "@/lib/auth/tokens";

/** For the meals route handlers: the user of a request — a personal API token
 *  (`Authorization: Bearer …`) or the session cookie — who must have `need` in the family. */
export async function requireFamilyRequest(req: Request, familyId: string, need: Role): Promise<User> {
  const user = getApiUser(req) ?? (await getAuth())?.user ?? null;
  if (!user) throw new AuthError(401, "Not signed in.");
  requireRole(db, { id: user.id }, familyId, need);
  return user;
}
