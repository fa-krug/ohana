"use client";

import { useState } from "react";
import { KeyRound } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { passkeyRegister } from "@/lib/auth-client/webauthn";
import { homeFor } from "@/lib/auth/redirect";
import { useT } from "@/lib/i18n/provider";
import { registerPasswordAction } from "@/app/actions/auth";

export function InviteForm({ code }: { code: string }) {
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
    const res = await registerPasswordAction({ email, name, password, inviteCode: code });
    setBusy(false);
    if (res.ok) window.location.href = homeFor(res.data);
    else setError(res.message || t("auth.errors.registrationFailed"));
  }

  async function onPasskey() {
    setBusy(true);
    setError("");
    try {
      const user = await passkeyRegister<{ onboardingStep: string }>({ email, name, inviteCode: code });
      window.location.href = homeFor(user);
    } catch (err) {
      if ((err as Error).name !== "NotAllowedError") setError((err as Error).message);
      setBusy(false);
    }
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <div className="space-y-2">
        <Label htmlFor="name">{t("invite.nameLabel")}</Label>
        <Input id="name" autoComplete="name" value={name} onChange={(e) => setName(e.target.value)} />
      </div>
      <div className="space-y-2">
        <Label htmlFor="email">{t("invite.emailLabel")}</Label>
        <Input id="email" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
      </div>
      <Button type="button" className="w-full" disabled={busy || !email} onClick={onPasskey}>
        <KeyRound className="size-4" /> {t("invite.registerWithPasskey")}
      </Button>
      <div className="space-y-2">
        <Label htmlFor="password">{t("invite.passwordLabel")}</Label>
        <Input id="password" type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} />
      </div>
      {error && <p className="text-sm font-medium text-destructive">{error}</p>}
      <Button type="submit" variant="outline" className="w-full" disabled={busy || !password || !email}>
        {t("invite.createAccount")}
      </Button>
    </form>
  );
}
