"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { useT } from "@/lib/i18n/provider";
import { DEVICE_CALLBACK } from "@/lib/auth/device-callback";
import { pairDeviceAction } from "@/app/actions/device";

export function PairButtons({ state, deviceName }: { state: string; deviceName: string }) {
  const { t } = useT();
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function onConnect() {
    setBusy(true);
    const res = await pairDeviceAction(state, deviceName);
    if (res.ok) {
      window.location.href = res.data.callbackUrl;
      return;
    }
    setBusy(false);
    setError(res.message || t("auth.devicePair.invalid"));
  }

  function onCancel() {
    window.location.href = `${DEVICE_CALLBACK}?${new URLSearchParams({ error: "cancelled", state })}`;
  }

  return (
    <div className="space-y-3">
      {error && <p className="text-sm font-medium text-destructive">{error}</p>}
      <Button className="w-full" onClick={onConnect} disabled={busy}>{t("auth.devicePair.connect")}</Button>
      <Button className="w-full" variant="ghost" onClick={onCancel} disabled={busy}>{t("common.cancel")}</Button>
    </div>
  );
}
