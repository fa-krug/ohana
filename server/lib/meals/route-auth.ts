import type { User } from "@/lib/auth/tokens";
import { requireFamilyApi } from "@/lib/families/api";
import type { Role } from "@/lib/families/roles";

/** For the meals route handlers: the user of a request's API token, who must have `need` in
 *  the family. */
export async function requireFamilyRequest(req: Request, familyId: string, need: Role): Promise<User> {
  return (await requireFamilyApi(req, familyId, need)).user;
}
