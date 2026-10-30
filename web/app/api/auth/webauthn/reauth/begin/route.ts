import { db } from "@/lib/db";
import { beginReauth } from "@/lib/auth/reauth";
import { setCeremonyCookie } from "@/lib/auth/ceremony-cookie";
import { assertSameOrigin } from "@/lib/auth/origin";
import { handle } from "@/lib/auth/route";
import { currentRpId, requireSessionUser } from "@/lib/auth/session";

export async function POST(req: Request) {
  return handle(async () => {
    assertSameOrigin(req);
    const user = await requireSessionUser();
    const { options, ceremony } = await beginReauth(db, user.id, await currentRpId());
    await setCeremonyCookie(ceremony);
    return options;
  });
}
