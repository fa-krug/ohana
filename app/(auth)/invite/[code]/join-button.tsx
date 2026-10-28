"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { useT } from "@/lib/i18n/provider";
import { acceptInviteAction } from "@/app/actions/families";

export function JoinButton({ code }: { code: string }) {
  const { t } = useT();
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function onJoin() {
    setBusy(true);
    setError("");
    const res = await acceptInviteAction(code);
    setBusy(false);
    if (res.ok) window.location.href = `/f/${res.data.familyId}`;
    else setError(res.message);
  }

  return (
    <div className="space-y-3">
      {error && <p className="text-sm font-medium text-destructive">{error}</p>}
      <Button className="w-full" onClick={onJoin} disabled={busy}>{t("invite.accept")}</Button>
    </div>
  );
}
