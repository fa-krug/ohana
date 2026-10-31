import { db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { handle } from "@/lib/auth/route";
import { getApiUser } from "@/lib/auth/session";
import { createFamilyForUser } from "@/lib/families/app-routes";

export const dynamic = "force-dynamic";

/** Creates a family for the API token's user (the native app's "New family"): `{ name }` →
 *  the family as GET /api/v1/me lists it. */
export async function POST(req: Request) {
  return handle(async () => {
    const user = getApiUser(req);
    if (!user) throw new AuthError(401, "A valid API token is required (Authorization: Bearer …).");
    const body = await req.json().catch(() => {
      throw new AuthError(400, "Body must be a JSON object");
    });
    return createFamilyForUser(db, user, body, req.headers.get("accept-language"), new Date());
  });
}
