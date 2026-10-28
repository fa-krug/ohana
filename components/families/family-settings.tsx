"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Copy, Link2, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import { RoleSelect } from "@/components/families/role-select";
import { copyText } from "@/lib/clipboard";
import { formatDate } from "@/lib/format";
import {
  addMemberAction,
  createInviteAction,
  deleteFamilyAction,
  removeMemberAction,
  renameFamilyAction,
  revokeInviteAction,
  setRoleAction,
} from "@/app/actions/families";

type Role = "editor" | "viewer";

interface Props {
  family: { id: string; name: string };
  role: Role;
  selfId: string;
  members: { userId: string; email: string; name: string; role: Role }[];
  invites: { id: string; url: string; role: string; expiresAt: Date }[];
}

export function FamilySettings(props: Props) {
  const { t } = useT();
  const editor = props.role === "editor";
  return (
    <div className="space-y-6">
      {!editor && <p className="rounded-md border bg-muted/50 p-3 text-sm">{t("settings.viewerNote")}</p>}
      <GeneralCard family={props.family} editor={editor} />
      <MembersCard {...props} editor={editor} />
      {editor && <InvitesCard familyId={props.family.id} invites={props.invites} />}
      <LeaveCard family={props.family} selfId={props.selfId} editor={editor} memberCount={props.members.length} />
    </div>
  );
}

function GeneralCard({ family, editor }: { family: Props["family"]; editor: boolean }) {
  const { t } = useT();
  const router = useRouter();
  const [name, setName] = useState(family.name);
  const [busy, setBusy] = useState(false);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    const res = await renameFamilyAction(family.id, { name });
    setBusy(false);
    if (!res.ok) return toast.error(res.message);
    toast.success(t("settings.renamed"));
    router.refresh();
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-lg">{t("settings.general")}</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={save} className="flex flex-col gap-2 sm:flex-row sm:items-end">
          <div className="flex-1 space-y-2">
            <Label htmlFor="family-name">{t("settings.familyName")}</Label>
            <Input id="family-name" value={name} maxLength={100} disabled={!editor} onChange={(e) => setName(e.target.value)} />
          </div>
          {editor && (
            <Button type="submit" disabled={busy || !name.trim() || name.trim() === family.name}>
              {t("common.save")}
            </Button>
          )}
        </form>
      </CardContent>
    </Card>
  );
}

function MembersCard({ family, members, selfId, editor }: Props & { editor: boolean }) {
  const { t } = useT();
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<Role>("editor");
  const [busy, setBusy] = useState(false);

  async function add(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    const res = await addMemberAction(family.id, { email, role });
    setBusy(false);
    if (!res.ok) return toast.error(res.message);
    toast.success(t("settings.memberAdded"));
    setEmail("");
    router.refresh();
  }

  async function changeRole(userId: string, next: Role) {
    const res = await setRoleAction(family.id, userId, next);
    if (!res.ok) return toast.error(res.message);
    toast.success(t("settings.roleChanged"));
    router.refresh();
  }

  async function remove(userId: string, label: string) {
    if (!window.confirm(t("settings.removeConfirm", { name: label }))) return;
    const res = await removeMemberAction(family.id, userId);
    if (!res.ok) return toast.error(res.message);
    toast.success(t("settings.memberRemoved"));
    router.refresh();
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-lg">{t("settings.members")}</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <ul className="divide-y rounded-md border">
          {members.map((m) => {
            const label = m.name || m.email;
            return (
              <li key={m.userId} className="flex flex-col gap-2 p-3 sm:flex-row sm:items-center">
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium">
                    {label}
                    {m.userId === selfId && <span className="text-muted-foreground"> ({t("common.you")})</span>}
                  </p>
                  {m.name && <p className="truncate text-xs text-muted-foreground">{m.email}</p>}
                </div>
                {editor && m.userId !== selfId ? (
                  <div className="flex items-center gap-2">
                    <RoleSelect value={m.role} onChange={(r) => changeRole(m.userId, r)} />
                    <Button variant="ghost" size="icon" aria-label={t("common.remove")} className="text-destructive hover:bg-destructive/10 hover:text-destructive" onClick={() => remove(m.userId, label)}>
                      <Trash2 className="size-4" />
                    </Button>
                  </div>
                ) : (
                  <span className="text-sm text-muted-foreground">{t(`roles.${m.role}`)}</span>
                )}
              </li>
            );
          })}
        </ul>
        {editor && (
          <form onSubmit={add} className="space-y-2">
            <Label htmlFor="member-email">{t("settings.addMember")}</Label>
            <div className="flex flex-col gap-2 sm:flex-row">
              <Input id="member-email" type="text" autoComplete="off" placeholder={t("settings.emailPlaceholder")} value={email} onChange={(e) => setEmail(e.target.value)} className="flex-1" />
              <RoleSelect value={role} onChange={setRole} />
              <Button type="submit" disabled={busy || !email.trim()}>{t("common.add")}</Button>
            </div>
            <p className="text-xs text-muted-foreground">{t("settings.addMemberHint")}</p>
          </form>
        )}
      </CardContent>
    </Card>
  );
}

function InvitesCard({ familyId, invites }: { familyId: string; invites: Props["invites"] }) {
  const { t, locale } = useT();
  const router = useRouter();
  const [role, setRole] = useState<Role>("editor");
  const [busy, setBusy] = useState(false);

  async function create() {
    setBusy(true);
    const res = await createInviteAction(familyId, role);
    setBusy(false);
    if (!res.ok) return toast.error(res.message);
    toast.success(t("settings.inviteCreated"));
    router.refresh();
  }

  async function revoke(id: string) {
    const res = await revokeInviteAction(familyId, id);
    if (!res.ok) return toast.error(res.message);
    toast.success(t("settings.inviteRevoked"));
    router.refresh();
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-lg">{t("settings.invites")}</CardTitle>
        <CardDescription>{t("settings.invitesHint")}</CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {invites.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t("settings.noInvites")}</p>
        ) : (
          <ul className="space-y-2">
            {invites.map((i) => (
              <li key={i.id} className="flex flex-col gap-2 rounded-md border p-3 sm:flex-row sm:items-center">
                <div className="min-w-0 flex-1">
                  <p className="truncate font-mono text-xs">{i.url}</p>
                  <p className="text-xs text-muted-foreground">
                    {t(`roles.${i.role}`)} · {t("settings.expires", { date: formatDate(i.expiresAt, locale) })}
                  </p>
                </div>
                <div className="flex gap-2">
                  <Button variant="outline" size="sm" onClick={() => copyText(i.url, t("common.copied"))}>
                    <Copy className="size-4" /> {t("common.copy")}
                  </Button>
                  <Button variant="ghost" size="sm" onClick={() => revoke(i.id)}>{t("settings.revoke")}</Button>
                </div>
              </li>
            ))}
          </ul>
        )}
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
          <Label className="shrink-0">{t("settings.inviteAs")}</Label>
          <RoleSelect value={role} onChange={setRole} />
          <Button variant="outline" disabled={busy} onClick={create}>
            <Link2 className="size-4" /> {t("settings.createInvite")}
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}

function LeaveCard({ family, selfId, editor, memberCount }: { family: Props["family"]; selfId: string; editor: boolean; memberCount: number }) {
  const { t } = useT();

  async function leave() {
    if (!window.confirm(t("settings.leaveConfirm", { family: family.name }))) return;
    const res = await removeMemberAction(family.id, selfId);
    if (!res.ok) return toast.error(res.message);
    toast.success(t("settings.left"));
    window.location.href = "/";
  }

  async function remove() {
    if (!window.confirm(t("settings.deleteConfirm", { family: family.name }))) return;
    const res = await deleteFamilyAction(family.id);
    if (!res.ok) return toast.error(res.message);
    toast.success(t("settings.deleted"));
    window.location.href = "/";
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-lg">{t("settings.leaveDelete")}</CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-2 sm:flex-row">
        {memberCount > 1 && <Button variant="outline" onClick={leave}>{t("settings.leave")}</Button>}
        {editor && (
          <Button variant="destructive" disabled={memberCount > 1} title={memberCount > 1 ? t("settings.deleteHint") : undefined} onClick={remove}>
            {t("settings.deleteFamily")}
          </Button>
        )}
        {editor && memberCount > 1 && <p className="self-center text-xs text-muted-foreground">{t("settings.deleteHint")}</p>}
      </CardContent>
    </Card>
  );
}
