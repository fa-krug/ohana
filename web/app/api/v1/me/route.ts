import { db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { handle } from "@/lib/auth/route";
import { serializeUser } from "@/lib/auth/serialize";
import { getApiUser } from "@/lib/auth/session";
import { deleteToken, findToken } from "@/lib/auth/tokens";
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

/** Signs the API token out: deletes it (the native app's "Sign out"). */
export async function DELETE(req: Request) {
  return handle(async () => {
    const match = /^Bearer\s+(\S+)$/i.exec(req.headers.get("authorization") ?? "");
    const found = match ? findToken(db, match[1], "api", new Date()) : null;
    if (!found) throw new AuthError(401, "A valid API token is required (Authorization: Bearer …).");
    deleteToken(db, found.token.id);
    return { ok: true };
  });
}
