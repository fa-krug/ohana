import { db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { completePasskeyLogin } from "@/lib/auth/passkey-auth";
import { clearCeremonyCookie, readCeremonyCookie } from "@/lib/auth/ceremony-cookie";
import { assertSameOrigin } from "@/lib/auth/origin";
import { handle } from "@/lib/auth/route";
import { serializeUser } from "@/lib/auth/serialize";
import { currentRpId, setSessionCookie } from "@/lib/auth/session";
import { passkeyCompleteSchema } from "@/lib/schemas/auth";

export async function POST(req: Request) {
  const ceremony = await readCeremonyCookie();
  try {
    return await handle(async () => {
      assertSameOrigin(req);
      const { credential } = passkeyCompleteSchema.parse(await req.json());
      if (!ceremony) throw new AuthError(400, "No login in progress.");
      const user = await completePasskeyLogin(db, { responseJson: credential }, ceremony, await currentRpId(), new Date());
      await setSessionCookie(user.id);
      return serializeUser(db, user);
    });
  } finally {
    await clearCeremonyCookie();
  }
}
