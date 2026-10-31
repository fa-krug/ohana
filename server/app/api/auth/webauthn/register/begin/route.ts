import { db } from "@/lib/db";
import { beginPasskeyRegistration } from "@/lib/auth/passkey-auth";
import { setCeremonyCookie } from "@/lib/auth/ceremony-cookie";
import { assertSameOrigin } from "@/lib/auth/origin";
import { handle } from "@/lib/auth/route";
import { currentRpId } from "@/lib/auth/session";
import { passkeyRegisterBeginSchema } from "@/lib/schemas/auth";

/** With an invite code: a new account joining a family. Without: the first account. */
export async function POST(req: Request) {
  return handle(async () => {
    assertSameOrigin(req);
    const args = passkeyRegisterBeginSchema.parse(await req.json());
    const { options, ceremony } = await beginPasskeyRegistration(db, args, await currentRpId(), new Date());
    await setCeremonyCookie(ceremony);
    return options;
  });
}
