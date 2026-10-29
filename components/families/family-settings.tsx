"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Cake, Check, Copy, Link2, Pencil, Trash2, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Checkbox } from "@/components/ui/checkbox";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import { RoleSelect } from "@/components/families/role-select";
import { copyText } from "@/lib/clipboard";
import { formatDate } from "@/lib/format";
import { ageOn } from "@/lib/families/birthdays";
import {
  addMemberAction,
  addPersonAction,
  createInviteAction,
  deleteFamilyAction,
  removeMemberAction,
  removePersonAction,
  renameFamilyAction,
  revokeInviteAction,
  setMemberBirthdayAction,
  setRoleAction,
  updatePersonAction,
} from "@/app/actions/families";

type Role = "editor" | "viewer";

interface Props {
  family: { id: string; name: string };
  role: Role;
  selfId: string;
  /** Public base URL, for the invite links. */
  appUrl: string;
  members: { userId: string; email: string; name: string; role: Role; birthday: string | null }[];
  /** Members without an account (children, …). */
  people: { id: string; name: string; birthday: string | null }[];
  invites: { id: string; url: string; role: string; expiresAt: Date; personId: string | null }[];
  /** More sections (one component each, e.g. home address, notifications), shown before
   *  "Leave or delete". */
  children?: React.ReactNode;
}

export function FamilySettings(props: Props) {
  const { t } = useT();
  const editor = props.role === "editor";
  return (
    <div className="space-y-6">
      {!editor && <p className="rounded-md border bg-muted/50 p-3 text-sm">{t("settings.viewerNote")}</p>}
      <GeneralCard family={props.family} editor={editor} />
      <MembersCard {...props} editor={editor} />
      {editor && <InvitesCard familyId={props.family.id} invites={props.invites} people={props.people} />}
      {props.children}
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

function MembersCard({ family, members, people, invites, selfId, editor, appUrl }: Props & { editor: boolean }) {
  const { t } = useT();
  const router = useRouter();
  const [name, setName] = useState("");
  const [birthday, setBirthday] = useState("");
  const [withInvite, setWithInvite] = useState(false);
  const [inviteRole, setInviteRole] = useState<Role>("viewer");
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<Role>("editor");
  const [busy, setBusy] = useState(false);

  async function addPerson(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    const res = await addPersonAction(family.id, { name, birthday, invite: withInvite ? inviteRole : null });
    setBusy(false);
    if (!res.ok) return toast.error(res.message);
    if (res.data.invite) await copyText(`${appUrl}/invite/${res.data.invite.code}`, t("settings.inviteCopied"));
    else toast.success(t("settings.memberAdded"));
    setName("");
    setBirthday("");
    setWithInvite(false);
    router.refresh();
  }

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

  const birthdayText = useBirthdayText();
  /** The account whose birthday is being edited. */
  const [birthdayOf, setBirthdayOf] = useState<string | null>(null);

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
            if (birthdayOf === m.userId) {
              return (
                <li key={m.userId} className="p-3">
                  <BirthdayForm
                    label={label}
                    value={m.birthday}
                    onCancel={() => setBirthdayOf(null)}
                    onSave={async (next) => {
                      const res = await setMemberBirthdayAction(family.id, m.userId, next);
                      if (!res.ok) return void toast.error(res.message);
                      toast.success(t("settings.birthdaySaved"));
                      setBirthdayOf(null);
                      router.refresh();
                    }}
                  />
                </li>
              );
            }
            return (
              <li key={m.userId} className="flex flex-col gap-2 p-3 sm:flex-row sm:items-center">
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium">
                    {label}
                    {m.userId === selfId && <span className="text-muted-foreground"> ({t("common.you")})</span>}
                  </p>
                  {(m.name || m.birthday) && (
                    <p className="truncate text-xs text-muted-foreground">
                      {[m.name ? m.email : "", m.birthday ? birthdayText(m.birthday) : ""].filter(Boolean).join(" · ")}
                    </p>
                  )}
                </div>
                {(editor || m.userId === selfId) && (
                  <Button variant="ghost" size="icon" aria-label={t("settings.setBirthday")} title={t("settings.setBirthday")} onClick={() => setBirthdayOf(m.userId)}>
                    <Cake className="size-4" />
                  </Button>
                )}
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
          {people.map((p) => (
            <PersonRow
              key={p.id}
              familyId={family.id}
              person={p}
              invite={invites.find((i) => i.personId === p.id) ?? null}
              editor={editor}
              appUrl={appUrl}
            />
          ))}
        </ul>
        {editor && (
          <>
            <form onSubmit={addPerson} className="space-y-2">
              <Label htmlFor="person-name">{t("settings.addMember")}</Label>
              <div className="flex flex-col gap-2 sm:flex-row">
                <Input id="person-name" autoComplete="off" maxLength={80} placeholder={t("settings.namePlaceholder")} value={name} onChange={(e) => setName(e.target.value)} className="flex-1" />
                <Input
                  type="date"
                  aria-label={t("settings.birthdayOptional")}
                  title={t("settings.birthdayOptional")}
                  max={todayLocal()}
                  value={birthday}
                  onChange={(e) => setBirthday(e.target.value)}
                  className="sm:w-44"
                />
                <Button type="submit" disabled={busy || !name.trim()}>{t("common.add")}</Button>
              </div>
              <div className="flex min-h-10 flex-wrap items-center gap-x-3 gap-y-2">
                <div className="flex items-center gap-2">
                  <Checkbox id="person-invite" checked={withInvite} onCheckedChange={(v) => setWithInvite(v === true)} />
                  <Label htmlFor="person-invite" className="font-normal">{t("settings.withInvite")}</Label>
                </div>
                {withInvite && (
                  <div className="flex items-center gap-2">
                    <Label htmlFor="person-invite-role" className="font-normal text-muted-foreground">{t("settings.inviteAs")}</Label>
                    <RoleSelect id="person-invite-role" value={inviteRole} onChange={setInviteRole} />
                  </div>
                )}
              </div>
              <p className="text-xs text-muted-foreground">{t("settings.addMemberHint")}</p>
            </form>
            <form onSubmit={add} className="space-y-2 border-t pt-4">
              <Label htmlFor="member-email">{t("settings.addByEmail")}</Label>
              <div className="flex flex-col gap-2 sm:flex-row">
                <Input id="member-email" type="text" autoComplete="off" placeholder={t("settings.emailPlaceholder")} value={email} onChange={(e) => setEmail(e.target.value)} className="flex-1" />
                <RoleSelect value={role} onChange={setRole} />
                <Button type="submit" variant="outline" disabled={busy || !email.trim()}>{t("common.add")}</Button>
              </div>
            </form>
          </>
        )}
      </CardContent>
    </Card>
  );
}

const pad = (n: number) => String(n).padStart(2, "0");

/** Today on this device, "YYYY-MM-DD" (the latest birthday a date field allows). */
function todayLocal(): string {
  const d = new Date();
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** "3 May 2019 · 7 years" for a birthday. */
function useBirthdayText(): (birthday: string) => string {
  const { t, locale } = useT();
  return (birthday) =>
    t("settings.birthdayAge", { count: ageOn(birthday, todayLocal()), date: formatDate(`${birthday}T00:00:00`, locale) });
}

/** An account member's birthday, edited in place of their row. */
function BirthdayForm({
  label,
  value,
  onSave,
  onCancel,
}: {
  label: string;
  value: string | null;
  onSave: (birthday: string | null) => Promise<void>;
  onCancel: () => void;
}) {
  const { t } = useT();
  const [birthday, setBirthday] = useState(value ?? "");
  const [busy, setBusy] = useState(false);
  return (
    <form
      onSubmit={async (e) => {
        e.preventDefault();
        setBusy(true);
        await onSave(birthday || null);
        setBusy(false);
      }}
      onKeyDown={(e) => e.key === "Escape" && onCancel()}
      className="flex flex-wrap items-center gap-2"
    >
      <span className="min-w-0 flex-1 truncate text-sm font-medium">{label}</span>
      <Input type="date" autoFocus aria-label={t("settings.birthday")} max={todayLocal()} value={birthday} onChange={(e) => setBirthday(e.target.value)} className="w-44" />
      <Button type="submit" size="icon" aria-label={t("common.save")} disabled={busy || birthday === (value ?? "")}>
        <Check className="size-4" />
      </Button>
      <Button type="button" variant="ghost" size="icon" aria-label={t("common.cancel")} onClick={onCancel}>
        <X className="size-4" />
      </Button>
    </form>
  );
}

/** A member without an account: name, birthday, whether an invite link is open, and for
 *  editors edit / invite / remove. */
function PersonRow({
  familyId,
  person,
  invite,
  editor,
  appUrl,
}: {
  familyId: string;
  person: Props["people"][number];
  invite: Props["invites"][number] | null;
  editor: boolean;
  appUrl: string;
}) {
  const { t } = useT();
  const router = useRouter();
  const birthdayText = useBirthdayText();
  const [mode, setMode] = useState<"view" | "edit" | "invite">("view");
  const [name, setName] = useState(person.name);
  const [birthday, setBirthday] = useState(person.birthday ?? "");
  const [role, setRole] = useState<Role>("viewer");
  const [busy, setBusy] = useState(false);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    const res = await updatePersonAction(familyId, person.id, { name, birthday });
    setBusy(false);
    if (!res.ok) return toast.error(res.message);
    toast.success(t("settings.personSaved"));
    setMode("view");
    router.refresh();
  }

  async function createInvite(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    const res = await createInviteAction(familyId, role, person.id);
    setBusy(false);
    if (!res.ok) return toast.error(res.message);
    await copyText(`${appUrl}/invite/${res.data.code}`, t("settings.inviteCopied"));
    setMode("view");
    router.refresh();
  }

  async function remove() {
    if (!window.confirm(t("settings.removeConfirm", { name: person.name }))) return;
    const res = await removePersonAction(familyId, person.id);
    if (!res.ok) return toast.error(res.message);
    toast.success(t("settings.memberRemoved"));
    router.refresh();
  }

  if (mode === "edit") {
    const unchanged = name.trim() === person.name && birthday === (person.birthday ?? "");
    return (
      <li className="p-3">
        <form onSubmit={save} onKeyDown={(e) => e.key === "Escape" && setMode("view")} className="flex flex-wrap items-center gap-2">
          <Input
            autoFocus
            aria-label={t("settings.namePlaceholder")}
            maxLength={80}
            value={name}
            onChange={(e) => setName(e.target.value)}
            className="min-w-40 flex-1"
          />
          <Input
            type="date"
            aria-label={t("settings.birthdayOptional")}
            title={t("settings.birthdayOptional")}
            max={todayLocal()}
            value={birthday}
            onChange={(e) => setBirthday(e.target.value)}
            className="w-44"
          />
          <Button type="submit" size="icon" aria-label={t("common.save")} disabled={busy || !name.trim() || unchanged}>
            <Check className="size-4" />
          </Button>
          <Button type="button" variant="ghost" size="icon" aria-label={t("common.cancel")} onClick={() => setMode("view")}>
            <X className="size-4" />
          </Button>
        </form>
      </li>
    );
  }

  return (
    <li className="flex flex-col gap-2 p-3 sm:flex-row sm:items-center">
      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-medium">{person.name}</p>
        <p className="truncate text-xs text-muted-foreground">
          {[invite ? t("settings.inviteOpen") : t("settings.noAccount"), person.birthday ? birthdayText(person.birthday) : ""].filter(Boolean).join(" · ")}
        </p>
      </div>
      {editor && mode === "invite" && (
        <form onSubmit={createInvite} className="flex items-center gap-2">
          <RoleSelect value={role} onChange={setRole} />
          <Button type="submit" variant="outline" disabled={busy}>
            <Link2 className="size-4" /> {t("settings.createInvite")}
          </Button>
          <Button type="button" variant="ghost" size="icon" aria-label={t("common.cancel")} onClick={() => setMode("view")}>
            <X className="size-4" />
          </Button>
        </form>
      )}
      {editor && mode === "view" && (
        <div className="flex items-center gap-1">
          {invite && (
            <Button variant="ghost" size="icon" aria-label={t("common.copy")} title={t("common.copy")} onClick={() => copyText(invite.url, t("common.copied"))}>
              <Copy className="size-4" />
            </Button>
          )}
          <Button variant="outline" size="sm" onClick={() => setMode("invite")}>
            <Link2 className="size-4" /> {t("settings.invitePerson")}
          </Button>
          <Button variant="ghost" size="icon" aria-label={t("common.edit")} title={t("common.edit")} onClick={() => { setName(person.name); setBirthday(person.birthday ?? ""); setMode("edit"); }}>
            <Pencil className="size-4" />
          </Button>
          <Button variant="ghost" size="icon" aria-label={t("common.remove")} className="text-destructive hover:bg-destructive/10 hover:text-destructive" onClick={remove}>
            <Trash2 className="size-4" />
          </Button>
        </div>
      )}
    </li>
  );
}

function InvitesCard({ familyId, invites, people }: { familyId: string; invites: Props["invites"]; people: Props["people"] }) {
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
            {invites.map((i) => {
              const person = i.personId ? people.find((p) => p.id === i.personId) : undefined;
              return (
                <li key={i.id} className="flex flex-col gap-2 rounded-md border p-3 sm:flex-row sm:items-center">
                  <div className="min-w-0 flex-1">
                    <p className="truncate font-mono text-xs">{i.url}</p>
                    <p className="text-xs text-muted-foreground">
                      {person && <>{t("settings.inviteFor", { name: person.name })} · </>}
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
              );
            })}
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
