"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Pencil, Plus, Send, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { NativeSelect } from "@/components/ui/native-select";
import { Switch } from "@/components/ui/switch";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import type { ChannelDto } from "@/lib/notifications/channels";
import { CHANNEL_PROVIDERS } from "@/lib/notifications/schema";
import { createChannelAction, deleteChannelAction, testChannelAction, updateChannelAction } from "@/app/actions/notifications";

const PROVIDER_LABEL: Record<string, string> = {
  PUSHBULLET: "Pushbullet",
  PUSHOVER: "Pushover",
  TELEGRAM: "Telegram",
  EMAIL: "Email",
};

/** The family's notification channels (editors only): every module sends through them. */
export function NotificationsCard({ familyId, channels }: { familyId: string; channels: ChannelDto[] }) {
  const { t } = useT();
  const router = useRouter();
  const [editing, setEditing] = useState<ChannelDto | "new" | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  async function test(c: ChannelDto) {
    setBusy(c.id);
    const res = await testChannelAction(familyId, c.id);
    setBusy(null);
    if (!res.ok) return void toast.error(t("notifications.channels.testFailed", { error: res.message }));
    toast.success(t("notifications.channels.testSent"));
  }

  async function remove(c: ChannelDto) {
    if (!window.confirm(t("notifications.channels.deleteConfirm", { name: c.name }))) return;
    const res = await deleteChannelAction(familyId, c.id);
    if (!res.ok) return void toast.error(res.message);
    toast.success(t("notifications.channels.deleted"));
    router.refresh();
  }

  return (
    <Card id="notifications" className="scroll-mt-20">
      <CardHeader>
        <CardTitle className="text-lg">{t("notifications.channels.title")}</CardTitle>
        <CardDescription>{t("notifications.channels.hint")}</CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {channels.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t("notifications.channels.none")}</p>
        ) : (
          <ul className="divide-y rounded-md border">
            {channels.map((c) => (
              <li key={c.id} className="flex flex-col gap-2 p-3 sm:flex-row sm:items-center">
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium">
                    {c.name}
                    {!c.enabled && <span className="font-normal text-muted-foreground"> ({t("notifications.channels.disabled")})</span>}
                  </p>
                  <p className="truncate text-xs text-muted-foreground">
                    {PROVIDER_LABEL[c.provider] ?? c.provider}
                    {c.target && ` · ${c.target}`}
                  </p>
                </div>
                <div className="flex gap-1">
                  <Button variant="outline" size="sm" disabled={busy === c.id} onClick={() => test(c)}>
                    <Send className="size-4" /> {t("notifications.channels.test")}
                  </Button>
                  <Button variant="ghost" size="icon" aria-label={t("common.edit")} onClick={() => setEditing(c)}>
                    <Pencil className="size-4" />
                  </Button>
                  <Button variant="ghost" size="icon" aria-label={t("common.delete")} className="text-destructive hover:bg-destructive/10 hover:text-destructive" onClick={() => remove(c)}>
                    <Trash2 className="size-4" />
                  </Button>
                </div>
              </li>
            ))}
          </ul>
        )}
        <Button variant="outline" onClick={() => setEditing("new")}>
          <Plus className="size-4" /> {t("notifications.channels.add")}
        </Button>
      </CardContent>
      <Dialog open={editing !== null} onOpenChange={(open) => !open && setEditing(null)}>
        <DialogContent className="max-h-[90dvh] overflow-y-auto">
          {editing !== null && (
            <ChannelForm
              familyId={familyId}
              channel={editing === "new" ? undefined : editing}
              onDone={() => {
                setEditing(null);
                router.refresh();
              }}
            />
          )}
        </DialogContent>
      </Dialog>
    </Card>
  );
}

function ChannelForm({ familyId, channel, onDone }: { familyId: string; channel?: ChannelDto; onDone: () => void }) {
  const { t } = useT();
  const [name, setName] = useState(channel?.name ?? "");
  const [provider, setProvider] = useState(channel?.provider ?? "PUSHBULLET");
  const [token, setToken] = useState("");
  const [target, setTarget] = useState(channel?.target ?? "");
  const [enabled, setEnabled] = useState(channel?.enabled ?? true);
  const [smtpHost, setSmtpHost] = useState(channel?.smtpHost ?? "");
  const [smtpPort, setSmtpPort] = useState(String(channel?.smtpPort ?? 465));
  const [smtpUsername, setSmtpUsername] = useState(channel?.smtpUsername ?? "");
  const [smtpFrom, setSmtpFrom] = useState(channel?.smtpFrom ?? "");
  const [busy, setBusy] = useState(false);
  const isEmail = provider === "EMAIL";

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    const input = { name, provider, token, target, enabled, smtpHost, smtpPort: Number(smtpPort) || 465, smtpUsername, smtpFrom };
    const res = channel ? await updateChannelAction(familyId, channel.id, input) : await createChannelAction(familyId, input);
    setBusy(false);
    if (!res.ok) return void toast.error(res.message);
    toast.success(t("notifications.channels.saved"));
    onDone();
  }

  const targetLabel =
    provider === "PUSHOVER"
      ? t("notifications.channels.userKey")
      : provider === "TELEGRAM"
        ? t("notifications.channels.chatId")
        : t("notifications.channels.recipient");
  const tokenLabel =
    provider === "EMAIL"
      ? t("notifications.channels.smtpPassword")
      : provider === "TELEGRAM"
        ? t("notifications.channels.botToken")
        : t("notifications.channels.token");

  return (
    <form onSubmit={save} className="space-y-4">
      <DialogHeader>
        <DialogTitle>{channel ? t("notifications.channels.editTitle") : t("notifications.channels.newTitle")}</DialogTitle>
        <DialogDescription>{t("notifications.channels.formHint")}</DialogDescription>
      </DialogHeader>
      <div className="space-y-2">
        <Label htmlFor="channel-name">{t("notifications.channels.name")}</Label>
        <Input id="channel-name" value={name} maxLength={100} onChange={(e) => setName(e.target.value)} placeholder={t("notifications.channels.namePlaceholder")} />
      </div>
      <div className="space-y-2">
        <Label htmlFor="channel-provider">{t("notifications.channels.provider")}</Label>
        <NativeSelect id="channel-provider" value={provider} onChange={(e) => setProvider(e.target.value)}>
          {CHANNEL_PROVIDERS.map((p) => (
            <option key={p} value={p}>{PROVIDER_LABEL[p]}</option>
          ))}
        </NativeSelect>
      </div>
      {isEmail && (
        <div className="grid grid-cols-[1fr_6rem] gap-2">
          <div className="space-y-2">
            <Label htmlFor="smtp-host">{t("notifications.channels.smtpHost")}</Label>
            <Input id="smtp-host" value={smtpHost} onChange={(e) => setSmtpHost(e.target.value)} placeholder="smtp.example.com" />
          </div>
          <div className="space-y-2">
            <Label htmlFor="smtp-port">{t("notifications.channels.smtpPort")}</Label>
            <Input id="smtp-port" value={smtpPort} inputMode="numeric" onChange={(e) => setSmtpPort(e.target.value)} />
          </div>
          <div className="col-span-2 space-y-2">
            <Label htmlFor="smtp-user">{t("notifications.channels.smtpUsername")}</Label>
            <Input id="smtp-user" value={smtpUsername} autoComplete="off" onChange={(e) => setSmtpUsername(e.target.value)} />
          </div>
          <div className="col-span-2 space-y-2">
            <Label htmlFor="smtp-from">{t("notifications.channels.smtpFrom")}</Label>
            <Input id="smtp-from" value={smtpFrom} onChange={(e) => setSmtpFrom(e.target.value)} placeholder={smtpUsername} />
          </div>
        </div>
      )}
      <div className="space-y-2">
        <Label htmlFor="channel-token">{tokenLabel}</Label>
        <Input
          id="channel-token"
          type="password"
          autoComplete="new-password"
          value={token}
          onChange={(e) => setToken(e.target.value)}
          placeholder={channel?.hasToken ? t("notifications.channels.tokenKeep") : ""}
        />
        {channel?.hasToken && <p className="text-xs text-muted-foreground">{t("notifications.channels.tokenSet")}</p>}
      </div>
      {provider !== "PUSHBULLET" && (
        <div className="space-y-2">
          <Label htmlFor="channel-target">{targetLabel}</Label>
          <Input id="channel-target" value={target} onChange={(e) => setTarget(e.target.value)} />
        </div>
      )}
      <label className="flex cursor-pointer items-center justify-between gap-2 text-sm">
        {t("notifications.channels.enabled")}
        <Switch checked={enabled} onCheckedChange={setEnabled} />
      </label>
      <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
        <Button type="button" variant="outline" onClick={onDone}>{t("common.cancel")}</Button>
        <Button type="submit" disabled={busy || !name.trim()}>{t("common.save")}</Button>
      </div>
    </form>
  );
}
