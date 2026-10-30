import { redirect } from "next/navigation";
import { getSession } from "@/lib/auth/session";
import { deviceTokenName, validPairState } from "@/lib/auth/device-pairing";
import { getI18n } from "@/lib/i18n/server";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { PairButtons } from "./pair-buttons";

/** Connects the native app (apple/) to the account: see lib/auth/device-pairing.ts. */
export default async function DevicePairPage({
  searchParams,
}: {
  searchParams: Promise<{ state?: string; deviceName?: string }>;
}) {
  const { state, deviceName } = await searchParams;
  const user = await getSession();
  if (!user) {
    const here = `/device/pair?${new URLSearchParams({ state: state ?? "", deviceName: deviceName ?? "" })}`;
    redirect(`/login?${new URLSearchParams({ next: here })}`);
  }
  if (user.onboardingStep !== "COMPLETED") redirect("/onboarding");
  const { t } = await getI18n();
  const valid = validPairState(state);
  return (
    <Card className="w-full max-w-sm">
      <CardHeader>
        <CardTitle className="text-xl">{t("auth.devicePair.title")}</CardTitle>
        <CardDescription>
          {valid
            ? t("auth.devicePair.description", { device: deviceTokenName(deviceName), name: user.name || user.email })
            : t("auth.devicePair.invalid")}
        </CardDescription>
      </CardHeader>
      {valid && (
        <CardContent>
          <PairButtons state={state} deviceName={deviceName ?? ""} />
        </CardContent>
      )}
    </Card>
  );
}
