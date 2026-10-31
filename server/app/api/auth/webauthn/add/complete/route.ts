import { db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { completeAddPasskey } from "@/lib/auth/passkey-management";
import { clearCeremonyCookie, readCeremonyCookie } from "@/lib/auth/ceremony-cookie";
import { assertSameOrigin } from "@/lib/auth/origin";
import { handle } from "@/lib/auth/route";
import { currentRpId, requireSessionUser } from "@/lib/auth/session";
import { passkeyCompleteSchema } from "@/lib/schemas/auth";

export async function POST(req: Request) {
  const ceremony = await readCeremonyCookie();
  try {
    return await handle(async () => {
      assertSameOrigin(req);
      const user = await requireSessionUser();
      const { credential, deviceName } = passkeyCompleteSchema.parse(await req.json());
      if (!ceremony) throw new AuthError(400, "No pending passkey addition.");
      return completeAddPasskey(
        db,
        { userId: user.id, responseJson: credential, deviceName },
        ceremony,
        await currentRpId(),
        new Date(),
      );
    });
  } finally {
    await clearCeremonyCookie();
  }
}
