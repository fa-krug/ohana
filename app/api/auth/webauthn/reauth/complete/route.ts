import { z } from "zod";
import { db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { changeEmail } from "@/lib/auth/email";
import { completeReauth } from "@/lib/auth/reauth";
import { clearCeremonyCookie, readCeremonyCookie } from "@/lib/auth/ceremony-cookie";
import { assertSameOrigin } from "@/lib/auth/origin";
import { handle } from "@/lib/auth/route";
import { serializeUser } from "@/lib/auth/serialize";
import { currentRpId, requireSessionUser } from "@/lib/auth/session";

const bodySchema = z.object({
  credential: z.string().min(1),
  newEmail: z.string().trim().toLowerCase().email(),
});

/** Confirms the user with a passkey, then changes their email. */
export async function POST(req: Request) {
  const ceremony = await readCeremonyCookie();
  try {
    return await handle(async () => {
      assertSameOrigin(req);
      const user = await requireSessionUser();
      const { credential, newEmail } = bodySchema.parse(await req.json());
      if (!ceremony) throw new AuthError(400, "No re-authentication in progress.");
      await completeReauth(db, { userId: user.id, responseJson: credential }, ceremony, await currentRpId());
      return serializeUser(db, changeEmail(db, user.id, newEmail));
    });
  } finally {
    await clearCeremonyCookie();
  }
}
