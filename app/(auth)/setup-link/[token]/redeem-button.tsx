"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { useT } from "@/lib/i18n/provider";
import { redeemSetupLinkAction } from "@/app/actions/auth";

export function RedeemButton({ token }: { token: string }) {
  const { t } = useT();
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function onRedeem() {
    setBusy(true);
    const res = await redeemSetupLinkAction(token);
    if (res.ok) {
      window.location.href = res.data.onboardingStep === "COMPLETED" ? "/account" : "/onboarding";
      return;
    }
    setBusy(false);
    setError(t("auth.setupLink.invalid"));
  }

  return (
    <div className="space-y-3">
      {error && <p className="text-sm font-medium text-destructive">{error}</p>}
      <Button className="w-full" onClick={onRedeem} disabled={busy || !!error}>{t("common.continue")}</Button>
    </div>
  );
}
