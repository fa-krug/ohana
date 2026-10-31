import { getI18n } from "@/lib/i18n/server";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { RedeemButton } from "./redeem-button";

/** The link only opens this page: the token is used up by the button, so link previews
 *  (chat apps fetch links to show a preview) can't use it up. */
export default async function SetupLinkPage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const { t } = await getI18n();
  return (
    <Card className="w-full max-w-sm">
      <CardHeader>
        <CardTitle className="text-xl">{t("auth.setupLink.title")}</CardTitle>
        <CardDescription>{t("auth.setupLink.description")}</CardDescription>
      </CardHeader>
      <CardContent>
        <RedeemButton token={token} />
      </CardContent>
    </Card>
  );
}
