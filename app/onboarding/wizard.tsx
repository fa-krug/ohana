"use client";

import { useState } from "react";
import { KeyRound } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { addPasskey } from "@/lib/auth-client/webauthn";
import { useT } from "@/lib/i18n/provider";
import { setPasswordAction, skipPasskeyAction } from "@/app/actions/auth";

export function OnboardingWizard({ step }: { step: string }) {
  const { t } = useT();
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [withPassword, setWithPassword] = useState(false);
  const [password, setPassword] = useState("");

  async function onAddPasskey() {
    setBusy(true);
    setError("");
    try {
      await addPasskey();
      window.location.href = "/";
    } catch (err) {
      if ((err as Error).name !== "NotAllowedError") setError((err as Error).message);
      setBusy(false);
    }
  }

  async function onSkip() {
    setBusy(true);
    await skipPasskeyAction();
    window.location.href = "/";
  }

  async function onPassword(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    const res = await setPasswordAction({ newPassword: password });
    if (res.ok) {
      window.location.reload();
      return;
    }
    setBusy(false);
    setError(res.message);
  }

  if (step === "SET_CREDENTIALS") {
    return (
      <Card className="w-full max-w-md">
        <CardHeader>
          <CardTitle className="text-xl sm:text-2xl">{t("onboarding.credentials.title")}</CardTitle>
          <CardDescription>{t("onboarding.credentials.description")}</CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          {error && <p className="text-sm font-medium text-destructive">{error}</p>}
          <Button className="w-full" onClick={onAddPasskey} disabled={busy}>
            <KeyRound className="size-4" /> {t("onboarding.credentials.passkey")}
          </Button>
          {withPassword ? (
            <form onSubmit={onPassword} className="space-y-3">
              <div className="space-y-2">
                <Label htmlFor="password">{t("onboarding.credentials.passwordLabel")}</Label>
                <Input id="password" type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} />
              </div>
              <Button type="submit" variant="outline" className="w-full" disabled={busy || !password}>
                {t("onboarding.credentials.savePassword")}
              </Button>
            </form>
          ) : (
            <Button variant="link" className="w-full" disabled={busy} onClick={() => setWithPassword(true)}>
              {t("onboarding.credentials.password")}
            </Button>
          )}
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className="w-full max-w-md">
      <CardHeader>
        <CardTitle className="text-xl sm:text-2xl">{t("onboarding.addPasskey.title")}</CardTitle>
        <CardDescription>{t("onboarding.addPasskey.description")}</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        {error && <p className="text-sm font-medium text-destructive">{error}</p>}
        <Button className="w-full" onClick={onAddPasskey} disabled={busy}>
          <KeyRound className="size-4" /> {t("onboarding.addPasskey.add")}
        </Button>
        <Button variant="outline" className="w-full" onClick={onSkip} disabled={busy}>
          {t("onboarding.addPasskey.skip")}
        </Button>
      </CardContent>
    </Card>
  );
}
