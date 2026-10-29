import { db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { getSession } from "@/lib/auth/session";
import { getInviteSummary } from "@/lib/families/invites";
import { getI18n } from "@/lib/i18n/server";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { InviteForm } from "./invite-form";
import { JoinButton } from "./join-button";

export const dynamic = "force-dynamic";

export default async function InvitePage({ params }: { params: Promise<{ code: string }> }) {
  const { code } = await params;
  const { t } = await getI18n();
  let familyName: string | null = null;
  let error = "";
  try {
    familyName = getInviteSummary(db, code, new Date()).familyName;
  } catch (e) {
    error = e instanceof AuthError ? e.message : t("invite.invalidInvite");
  }
  const user = await getSession();

  if (!familyName) {
    return (
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle className="text-xl">{t("invite.title")}</CardTitle>
          <CardDescription className="text-destructive">{error}</CardDescription>
        </CardHeader>
      </Card>
    );
  }

  return (
    <Card className="w-full max-w-sm">
      <CardHeader>
        <CardTitle className="text-xl">{t("invite.join", { family: familyName })}</CardTitle>
        <CardDescription>{user ? t("invite.signedInDescription") : t("invite.createAccountDescription")}</CardDescription>
      </CardHeader>
      <CardContent>{user ? <JoinButton code={code} /> : <InviteForm code={code} />}</CardContent>
    </Card>
  );
}
