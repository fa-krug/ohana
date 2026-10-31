import { db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { getApiUser } from "@/lib/auth/session";
import type { User } from "@/lib/auth/tokens";
import { type Role, requireRole } from "./roles";

/** The user of an API request: an API token (`Authorization: Bearer …`, what the app pairs
 *  for); 401 without one, 403 while the account still has to set its credentials. There is no
 *  web UI, so the API doesn't read the session cookie here. */
export function requireApiUser(req: Request): User {
  const user = getApiUser(req);
  if (!user) throw new AuthError(401, "A valid API token is required (Authorization: Bearer …).");
  if (user.onboardingStep === "SET_CREDENTIALS") throw new AuthError(403, "Set your password first");
  return user;
}

/** For the separate routes under /api/v1/families/{familyId}: the user and their role;
 *  401 / 403 / 404 as AuthError. */
export async function requireFamilyApi(req: Request, familyId: string, need: Role = "viewer"): Promise<{ user: User; role: Role }> {
  const user = requireApiUser(req);
  return { user, role: requireRole(db, { id: user.id }, familyId, need) };
}
