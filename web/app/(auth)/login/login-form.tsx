"use client";

import { useState } from "react";
import { KeyRound } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { passkeyLogin } from "@/lib/auth-client/webauthn";
import { homeFor } from "@/lib/auth/redirect";
import { useT } from "@/lib/i18n/provider";
import { loginPasswordAction } from "@/app/actions/auth";

export function LoginForm({ next = null }: { next?: string | null }) {
  const { t } = useT();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [usePassword, setUsePassword] = useState(false);

  // After signing in: `next` (a path of this site), after the onboarding if it still needs one.
  const target = (user: { onboardingStep: string }) => homeFor(user, next);

  async function onPassword() {
    setBusy(true);
    setError("");
    const res = await loginPasswordAction({ email, password });
    setBusy(false);
    if (res.ok) window.location.href = target(res.data);
    else setError(res.message || t("auth.errors.loginFailed"));
  }

  async function onPasskey() {
    setBusy(true);
    setError("");
    try {
      const user = await passkeyLogin<{ onboardingStep: string }>(email.trim() || undefined);
      window.location.href = target(user);
    } catch (err) {
      if ((err as Error).name !== "NotAllowedError") setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (usePassword) void onPassword();
    else void onPasskey();
  }

  return (
    <Card className="w-full max-w-md">
      <CardHeader>
        <CardTitle className="text-xl sm:text-2xl">{t("auth.login.title")}</CardTitle>
        <CardDescription>{t("auth.login.subtitle")}</CardDescription>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="email">{t("auth.login.emailLabel")}</Label>
            <Input
              id="email"
              type="text"
              autoComplete="username webauthn"
              required={usePassword}
              value={email}
              onChange={(e) => setEmail(e.target.value)}
            />
          </div>
          {usePassword && (
            <div className="space-y-2">
              <Label htmlFor="password">{t("auth.login.passwordLabel")}</Label>
              <Input id="password" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} />
            </div>
          )}
          {error && <p className="text-sm font-medium text-destructive">{error}</p>}
          <Button type="submit" className="w-full" disabled={busy}>
            {usePassword ? t("auth.login.submit") : <><KeyRound className="size-4" /> {t("auth.login.signInWithPasskey")}</>}
          </Button>
          <Button type="button" variant="link" className="w-full" disabled={busy} onClick={() => { setError(""); setUsePassword((p) => !p); }}>
            {usePassword ? t("auth.login.usePasskeyInstead") : t("auth.login.usePasswordInstead")}
          </Button>
          {usePassword && <p className="text-center text-xs text-muted-foreground">{t("auth.login.forgot")}</p>}
        </form>
      </CardContent>
    </Card>
  );
}
