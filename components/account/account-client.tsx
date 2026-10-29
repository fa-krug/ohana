"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Copy, KeyRound, Pencil, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { NativeSelect } from "@/components/ui/native-select";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import { parseTheme, THEMES } from "@/lib/theme";
import { setTheme, useTheme } from "@/lib/theme-client";
import { addPasskey, reauthAndChangeEmail } from "@/lib/auth-client/webauthn";
import { copyText } from "@/lib/clipboard";
import { formatDate } from "@/lib/format";
import { removePasswordAction, setPasswordAction } from "@/app/actions/auth";
import {
  changeEmailAction,
  createApiTokenAction,
  deleteApiTokenAction,
  deletePasskeyAction,
  renamePasskeyAction,
  signOutOthersAction,
  updateProfileAction,
} from "@/app/actions/account";

interface PasskeyDto { id: string; deviceName: string; createdAt: Date; lastUsedAt: Date | null }
interface TokenDto { id: string; name: string; createdAt: Date; lastUsedAt: Date | null }

type Res = { ok: true } | { ok: false; message: string };

/** Shows the outcome of an action; true when it worked. */
function useDone() {
  const router = useRouter();
  return (res: Res, message: string): boolean => {
    if (!res.ok) {
      toast.error(res.message);
      return false;
    }
    toast.success(message);
    router.refresh();
    return true;
  };
}

export function AccountClient(props: {
  name: string;
  email: string;
  hasPassword: boolean;
  canReset: boolean;
  passkeys: PasskeyDto[];
  tokens: TokenDto[];
}) {
  const { t } = useT();
  return (
    <div className="space-y-6">
      {props.canReset && (
        <p className="rounded-md border border-primary bg-primary/10 p-3 text-sm">{t("account.resetBanner")}</p>
      )}
      <Card>
        <CardHeader><CardTitle className="text-lg">{t("account.profile")}</CardTitle></CardHeader>
        <CardContent className="space-y-5">
          <NameSection name={props.name} />
          <EmailSection email={props.email} hasPassword={props.hasPassword} hasPasskey={props.passkeys.length > 0} />
          <LanguageSection />
          <ThemeSection />
        </CardContent>
      </Card>
      <Card>
        <CardHeader><CardTitle className="text-lg">{t("account.security")}</CardTitle></CardHeader>
        <CardContent className="space-y-6">
          <PasskeysSection passkeys={props.passkeys} />
          <PasswordSection hasPassword={props.hasPassword} canReset={props.canReset} hasPasskey={props.passkeys.length > 0} />
          <SignOutOthers />
        </CardContent>
      </Card>
      <TokensCard tokens={props.tokens} />
    </div>
  );
}

function NameSection({ name }: { name: string }) {
  const { t } = useT();
  const done = useDone();
  const [value, setValue] = useState(name);
  return (
    <form
      className="flex flex-col gap-2 sm:flex-row sm:items-end"
      onSubmit={async (e) => {
        e.preventDefault();
        done(await updateProfileAction({ name: value }), t("account.nameSaved"));
      }}
    >
      <div className="flex-1 space-y-2">
        <Label htmlFor="name">{t("account.name")}</Label>
        <Input id="name" value={value} maxLength={100} onChange={(e) => setValue(e.target.value)} />
      </div>
      <Button type="submit" variant="outline" disabled={value.trim() === name}>{t("common.save")}</Button>
    </form>
  );
}

function EmailSection({ email, hasPassword, hasPasskey }: { email: string; hasPassword: boolean; hasPasskey: boolean }) {
  const { t } = useT();
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [newEmail, setNewEmail] = useState(email);
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);

  async function withPassword() {
    setBusy(true);
    const res = await changeEmailAction({ newEmail, currentPassword: password });
    setBusy(false);
    if (!res.ok) return toast.error(res.message);
    toast.success(t("account.emailUpdated"));
    setOpen(false);
    router.refresh();
  }

  async function withPasskey() {
    setBusy(true);
    try {
      await reauthAndChangeEmail(newEmail);
      toast.success(t("account.emailUpdated"));
      setOpen(false);
      router.refresh();
    } catch (e) {
      if ((e as Error).name !== "NotAllowedError") toast.error((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
      <div className="min-w-0">
        <Label>{t("account.email")}</Label>
        <p className="truncate text-sm text-muted-foreground">{email}</p>
      </div>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogTrigger asChild><Button variant="outline">{t("account.changeEmail")}</Button></DialogTrigger>
        <DialogContent>
          <DialogHeader><DialogTitle>{t("account.changeEmail")}</DialogTitle></DialogHeader>
          <div className="space-y-3">
            <div className="space-y-1.5">
              <Label htmlFor="new-email">{t("account.newEmail")}</Label>
              <Input id="new-email" type="email" value={newEmail} onChange={(e) => setNewEmail(e.target.value)} />
            </div>
            {hasPassword ? (
              <>
                <div className="space-y-1.5">
                  <Label htmlFor="email-password">{t("account.currentPassword")}</Label>
                  <Input id="email-password" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} />
                </div>
                <Button className="w-full" disabled={busy} onClick={withPassword}>{t("common.save")}</Button>
                {hasPasskey && (
                  <button type="button" className="text-xs text-muted-foreground underline" disabled={busy} onClick={withPasskey}>
                    {t("account.usePasskeyInstead")}
                  </button>
                )}
              </>
            ) : (
              <Button className="w-full" disabled={busy} onClick={withPasskey}>{t("account.confirmPasskey")}</Button>
            )}
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function LanguageSection() {
  const { locale, setLocale, t } = useT();
  return (
    <div className="space-y-2">
      <Label>{t("account.language")}</Label>
      <div className="flex gap-2">
        {(["en", "de"] as const).map((lang) => (
          <Button key={lang} variant={lang === locale ? "default" : "outline"} onClick={() => setLocale(lang)}>
            {t(`languages.${lang}`)}
          </Button>
        ))}
      </div>
    </div>
  );
}

/** Light / dark / like the system; kept per device (localStorage), not in the account. */
function ThemeSection() {
  const { t } = useT();
  const theme = useTheme();
  return (
    <div className="space-y-2">
      <Label htmlFor="theme">{t("account.theme")}</Label>
      <NativeSelect
        id="theme"
        className="sm:w-60"
        value={theme}
        onChange={(e) => setTheme(parseTheme(e.target.value))}
        aria-describedby="theme-hint"
      >
        {THEMES.map((th) => (
          <option key={th} value={th}>{t(`account.themes.${th}`)}</option>
        ))}
      </NativeSelect>
      <p id="theme-hint" className="text-xs text-muted-foreground">{t("account.themeHint")}</p>
    </div>
  );
}

function PasskeysSection({ passkeys }: { passkeys: PasskeyDto[] }) {
  const { t, locale } = useT();
  const router = useRouter();
  const done = useDone();

  async function add() {
    try {
      await addPasskey();
      toast.success(t("account.passkeyAdded"));
      router.refresh();
    } catch (e) {
      if ((e as Error).name !== "NotAllowedError") toast.error((e as Error).message);
    }
  }

  async function rename(p: PasskeyDto) {
    const name = window.prompt(t("common.rename"), p.deviceName);
    if (name === null) return;
    done(await renamePasskeyAction(p.id, name), t("account.passkeyRenamed"));
  }

  return (
    <div className="space-y-2">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <Label>{t("account.passkeys")}</Label>
          <p className="text-xs text-muted-foreground">{t("account.passkeysHint")}</p>
        </div>
        <Button variant="outline" onClick={add}><KeyRound className="size-4" /> {t("account.addPasskey")}</Button>
      </div>
      {passkeys.length === 0 && <p className="text-sm text-muted-foreground">{t("account.noPasskeys")}</p>}
      {passkeys.map((p) => (
        <div key={p.id} className="flex items-center gap-2 rounded-md border p-3 text-sm">
          <div className="min-w-0 flex-1">
            <p className="truncate font-medium">{p.deviceName || t("account.passkeyFallbackName")}</p>
            <p className="text-xs text-muted-foreground">
              {t("account.created", { date: formatDate(p.createdAt, locale) })}
              {" · "}
              {t("account.lastUsed", { date: p.lastUsedAt ? formatDate(p.lastUsedAt, locale) : t("common.never") })}
            </p>
          </div>
          <Button variant="ghost" size="icon" aria-label={t("common.rename")} onClick={() => rename(p)}>
            <Pencil className="size-4" />
          </Button>
          <Button variant="ghost" size="icon" aria-label={t("common.delete")} className="text-destructive hover:bg-destructive/10 hover:text-destructive"
            onClick={async () => done(await deletePasskeyAction(p.id), t("account.passkeyRemoved"))}>
            <Trash2 className="size-4" />
          </Button>
        </div>
      ))}
    </div>
  );
}

function PasswordSection({ hasPassword, canReset, hasPasskey }: { hasPassword: boolean; canReset: boolean; hasPasskey: boolean }) {
  const { t } = useT();
  const done = useDone();
  const [open, setOpen] = useState(false);
  const [removing, setRemoving] = useState(false);
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [busy, setBusy] = useState(false);
  const needsCurrent = hasPassword && !canReset;
  const title = hasPassword ? t("account.changePassword") : t("account.setPassword");

  async function save() {
    setBusy(true);
    const ok = done(await setPasswordAction({ currentPassword: current || undefined, newPassword: next }), t("account.passwordUpdated"));
    setBusy(false);
    if (ok) { setOpen(false); setCurrent(""); setNext(""); }
  }

  async function remove() {
    setBusy(true);
    const ok = done(await removePasswordAction({ currentPassword: current }), t("account.passwordRemoved"));
    setBusy(false);
    if (ok) { setRemoving(false); setCurrent(""); }
  }

  return (
    <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
      <div className="min-w-0">
        <Label>{t("account.password")}</Label>
        <p className="text-sm text-muted-foreground">{hasPassword ? t("account.passwordSet") : t("account.noPassword")}</p>
      </div>
      <div className="flex gap-2">
        <Dialog open={open} onOpenChange={setOpen}>
          <DialogTrigger asChild><Button variant="outline">{title}</Button></DialogTrigger>
          <DialogContent>
            <DialogHeader><DialogTitle>{title}</DialogTitle></DialogHeader>
            <form className="space-y-3" onSubmit={(e) => { e.preventDefault(); void save(); }}>
              {needsCurrent && (
                <div className="space-y-1.5">
                  <Label htmlFor="pw-current">{t("account.currentPassword")}</Label>
                  <Input id="pw-current" type="password" autoComplete="current-password" value={current} onChange={(e) => setCurrent(e.target.value)} />
                </div>
              )}
              <div className="space-y-1.5">
                <Label htmlFor="pw-new">{t("account.newPassword")}</Label>
                <Input id="pw-new" type="password" autoComplete="new-password" value={next} onChange={(e) => setNext(e.target.value)} />
              </div>
              <Button type="submit" className="w-full" disabled={busy || !next}>{t("common.save")}</Button>
            </form>
          </DialogContent>
        </Dialog>
        {hasPassword && hasPasskey && (
          <Dialog open={removing} onOpenChange={setRemoving}>
            <DialogTrigger asChild><Button variant="ghost">{t("account.removePassword")}</Button></DialogTrigger>
            <DialogContent>
              <DialogHeader><DialogTitle>{t("account.removePassword")}</DialogTitle></DialogHeader>
              <form className="space-y-3" onSubmit={(e) => { e.preventDefault(); void remove(); }}>
                <p className="text-sm text-muted-foreground">{t("account.removePasswordHint")}</p>
                <div className="space-y-1.5">
                  <Label htmlFor="pw-remove">{t("account.currentPassword")}</Label>
                  <Input id="pw-remove" type="password" autoComplete="current-password" value={current} onChange={(e) => setCurrent(e.target.value)} />
                </div>
                <Button type="submit" variant="destructive" className="w-full" disabled={busy || !current}>{t("account.removePassword")}</Button>
              </form>
            </DialogContent>
          </Dialog>
        )}
      </div>
    </div>
  );
}

function SignOutOthers() {
  const { t } = useT();
  const done = useDone();
  return (
    <Button variant="outline" onClick={async () => done(await signOutOthersAction(), t("account.signedOutOthers"))}>
      {t("account.signOutOthers")}
    </Button>
  );
}

function TokensCard({ tokens }: { tokens: TokenDto[] }) {
  const { t, locale } = useT();
  const router = useRouter();
  const done = useDone();
  const [name, setName] = useState("");
  const [created, setCreated] = useState<string | null>(null);

  async function create(e: React.FormEvent) {
    e.preventDefault();
    const res = await createApiTokenAction({ name });
    if (!res.ok) return toast.error(res.message);
    setCreated(res.data.token);
    setName("");
    router.refresh();
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-lg">{t("account.apiTokens")}</CardTitle>
        <CardDescription>{t("account.apiTokensHint")}</CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {created && (
          <div className="space-y-2 rounded-md border border-primary bg-primary/10 p-3">
            <p className="text-sm">{t("account.tokenCreated")}</p>
            <div className="flex gap-2">
              <Input readOnly value={created} className="font-mono text-xs" onFocus={(e) => e.target.select()} />
              <Button variant="outline" onClick={() => copyText(created, t("common.copied"))}><Copy className="size-4" /></Button>
            </div>
          </div>
        )}
        {tokens.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t("account.noTokens")}</p>
        ) : (
          <ul className="space-y-2">
            {tokens.map((tk) => (
              <li key={tk.id} className="flex items-center gap-2 rounded-md border p-3 text-sm">
                <div className="min-w-0 flex-1">
                  <p className="truncate font-medium">{tk.name}</p>
                  <p className="text-xs text-muted-foreground">
                    {t("account.created", { date: formatDate(tk.createdAt, locale) })}
                    {" · "}
                    {t("account.lastUsed", { date: tk.lastUsedAt ? formatDate(tk.lastUsedAt, locale) : t("common.never") })}
                  </p>
                </div>
                <Button variant="ghost" size="icon" aria-label={t("common.delete")} className="text-destructive hover:bg-destructive/10 hover:text-destructive"
                  onClick={async () => done(await deleteApiTokenAction(tk.id), t("account.tokenDeleted"))}>
                  <Trash2 className="size-4" />
                </Button>
              </li>
            ))}
          </ul>
        )}
        <form onSubmit={create} className="flex flex-col gap-2 sm:flex-row sm:items-end">
          <div className="flex-1 space-y-2">
            <Label htmlFor="token-name">{t("account.tokenName")}</Label>
            <Input id="token-name" value={name} maxLength={100} placeholder={t("account.tokenNamePlaceholder")} onChange={(e) => setName(e.target.value)} />
          </div>
          <Button type="submit" variant="outline" disabled={!name.trim()}>{t("account.createToken")}</Button>
        </form>
      </CardContent>
    </Card>
  );
}
