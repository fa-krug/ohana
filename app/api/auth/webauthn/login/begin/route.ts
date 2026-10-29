import { db } from "@/lib/db";
import { beginPasskeyLogin } from "@/lib/auth/passkey-auth";
import { setCeremonyCookie } from "@/lib/auth/ceremony-cookie";
import { assertSameOrigin } from "@/lib/auth/origin";
import { handle } from "@/lib/auth/route";
import { currentRpId } from "@/lib/auth/session";
import { passkeyLoginBeginSchema } from "@/lib/schemas/auth";

export async function POST(req: Request) {
  return handle(async () => {
    assertSameOrigin(req);
    const args = passkeyLoginBeginSchema.parse(await req.json().catch(() => ({})));
    const { options, ceremony } = await beginPasskeyLogin(db, args, await currentRpId());
    await setCeremonyCookie(ceremony);
    return options;
  });
}
