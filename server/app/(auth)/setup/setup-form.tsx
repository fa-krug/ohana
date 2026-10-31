"use client";

import { useState } from "react";
import { KeyRound } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { passkeyRegister } from "@/lib/auth-client/webauthn";
import { homeFor } from "@/lib/auth/redirect";
import { useT } from "@/lib/i18n/provider";
import { registerFirstUserPasswordAction } from "@/app/actions/auth";

export function SetupForm({ next = null }: { next?: string | null }) {
  const { t } = useT();
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    const res = await registerFirstUserPasswordAction({ email, name, password });
    setBusy(false);
    if (res.ok) window.location.href = homeFor(res.data, next);
    else setError(res.message || t("auth.errors.setupFailed"));
  }

  async function onPasskey() {
    setBusy(true);
    setError("");
    try {
      const user = await passkeyRegister<{ onboardingStep: string }>({ email, name });
      window.location.href = homeFor(user, next);
    } catch (err) {
      if ((err as Error).name !== "NotAllowedError") setError((err as Error).message);
      setBusy(false);
    }
  }

  return (
    <Card className="w-full max-w-md">
      <CardHeader>
        <CardTitle className="text-xl sm:text-2xl">{t("auth.setup.title")}</CardTitle>
        <CardDescription>{t("auth.setup.subtitle")}</CardDescription>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="name">{t("auth.setup.nameLabel")}</Label>
            <Input id="name" autoComplete="name" value={name} onChange={(e) => setName(e.target.value)} />
          </div>
          <div className="space-y-2">
            <Label htmlFor="email">{t("auth.setup.emailLabel")}</Label>
            <Input id="email" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
          </div>
          <div className="space-y-2">
            <Label htmlFor="password">{t("auth.setup.passwordLabel")}</Label>
            <Input id="password" type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} />
          </div>
          {error && <p className="text-sm font-medium text-destructive">{error}</p>}
          <Button type="submit" className="w-full" disabled={busy || !password}>{t("auth.setup.submit")}</Button>
          <Button type="button" variant="outline" className="w-full" disabled={busy || !email} onClick={onPasskey}>
            <KeyRound className="size-4" /> {t("auth.setup.withPasskey")}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}
