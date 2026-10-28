import { db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { handle } from "@/lib/auth/route";
import { serializeUser } from "@/lib/auth/serialize";
import { getApiUser } from "@/lib/auth/session";
import { listFamiliesOf } from "@/lib/families/manage";

export const dynamic = "force-dynamic";

/** Who the API token belongs to, and their families. */
export async function GET(req: Request) {
  return handle(async () => {
    const user = getApiUser(req);
    if (!user) throw new AuthError(401, "A valid API token is required (Authorization: Bearer …).");
    return { user: serializeUser(db, user), families: listFamiliesOf(db, user.id) };
  });
}
