"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Pencil, Plus, Trash2, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import { RoleSelect } from "@/components/families/role-select";
import {
  adminAddMemberAction,
  adminCreateFamilyAction,
  adminDeleteFamilyAction,
  adminRemoveMemberAction,
  adminRenameFamilyAction,
  adminSetRoleAction,
} from "@/app/actions/admin";

type Role = "editor" | "viewer";

interface FamilyRow {
  id: string;
  name: string;
  members: { userId: string; email: string; name: string; role: Role }[];
}

type Res = { ok: true } | { ok: false; message: string };

export function AdminFamilies({ families }: { families: FamilyRow[] }) {
  const { t } = useT();
  const router = useRouter();

  async function create() {
    const name = window.prompt(t("admin.newFamily"));
    if (!name?.trim()) return;
    const res = await adminCreateFamilyAction({ name });
    if (!res.ok) return toast.error(res.message);
    router.refresh();
  }

  return (
    <div className="space-y-4">
      <p className="text-sm text-muted-foreground">{t("admin.familiesHint")}</p>
      <Button onClick={create}><Plus className="size-4" /> {t("admin.newFamily")}</Button>
      {families.map((f) => <FamilyCard key={f.id} family={f} />)}
    </div>
  );
}

function FamilyCard({ family }: { family: FamilyRow }) {
  const { t } = useT();
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<Role>("editor");

  async function act(p: Promise<Res>, message?: string): Promise<boolean> {
    const res = await p;
    if (!res.ok) {
      toast.error(res.message);
      return false;
    }
    if (message) toast.success(message);
    router.refresh();
    return true;
  }

  async function rename() {
    const name = window.prompt(t("common.rename"), family.name);
    if (name?.trim()) await act(adminRenameFamilyAction(family.id, { name }));
  }

  async function remove() {
    if (!window.confirm(t("admin.deleteFamilyConfirm", { family: family.name }))) return;
    await act(adminDeleteFamilyAction(family.id), t("admin.familyDeleted"));
  }

  async function add(e: React.FormEvent) {
    e.preventDefault();
    if (await act(adminAddMemberAction(family.id, { email, role }))) setEmail("");
  }

  return (
    <Card>
      <CardHeader className="flex flex-row items-center gap-2 space-y-0">
        <CardTitle className="min-w-0 flex-1 truncate text-lg">{family.name}</CardTitle>
        <Button variant="ghost" size="icon" aria-label={t("common.rename")} onClick={rename}><Pencil className="size-4" /></Button>
        <Button variant="ghost" size="icon" aria-label={t("common.delete")} className="text-destructive hover:bg-destructive/10 hover:text-destructive" onClick={remove}>
          <Trash2 className="size-4" />
        </Button>
      </CardHeader>
      <CardContent className="space-y-3">
        {family.members.length === 0 && <p className="text-sm text-muted-foreground">{t("admin.noMembers")}</p>}
        <ul className="space-y-2">
          {family.members.map((m) => (
            <li key={m.userId} className="flex items-center gap-2 text-sm">
              <span className="min-w-0 flex-1 truncate">{m.name ? `${m.name} (${m.email})` : m.email}</span>
              <RoleSelect value={m.role} onChange={(r) => act(adminSetRoleAction(family.id, m.userId, r))} />
              <Button variant="ghost" size="icon" aria-label={t("common.remove")} onClick={() => act(adminRemoveMemberAction(family.id, m.userId))}>
                <X className="size-4" />
              </Button>
            </li>
          ))}
        </ul>
        <form onSubmit={add} className="flex flex-col gap-2 sm:flex-row">
          <Input placeholder={t("settings.emailPlaceholder")} value={email} onChange={(e) => setEmail(e.target.value)} className="flex-1" />
          <RoleSelect value={role} onChange={setRole} />
          <Button type="submit" variant="outline" disabled={!email.trim()}>{t("admin.addMember")}</Button>
        </form>
      </CardContent>
    </Card>
  );
}
