import { db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { getApiUser, getSession } from "@/lib/auth/session";
import type { User } from "@/lib/auth/tokens";
import { type Role, requireRole } from "./roles";

/** For route handlers under /api/v1/families/[familyId]: the user (API token or session
 *  cookie) and their role; 401 / 404 / 403 as AuthError. */
export async function requireFamilyApi(req: Request, familyId: string, need: Role = "viewer"): Promise<{ user: User; role: Role }> {
  const user = getApiUser(req) ?? (await getSession());
  if (!user) throw new AuthError(401, "Not signed in.");
  return { user, role: requireRole(db, { id: user.id }, familyId, need) };
}
