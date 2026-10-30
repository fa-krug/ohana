"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Copy, Link2, Pencil, Plus, ShieldCheck, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent } from "@/components/ui/card";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import { copyText } from "@/lib/clipboard";
import {
  adminCreateUserAction,
  adminDeleteUserAction,
  adminResetUserAction,
  adminUpdateUserAction,
} from "@/app/actions/admin";

interface UserRow {
  id: string;
  email: string;
  name: string;
  isAdmin: boolean;
  hasPassword: boolean;
  passkeyCount: number;
  familyCount: number;
  onboardingStep: string;
}

export function AdminUsers({ selfId, users }: { selfId: string; users: UserRow[] }) {
  const { t } = useT();
  const router = useRouter();
  const [editing, setEditing] = useState<UserRow | "new" | null>(null);
  const [link, setLink] = useState<{ title: string; url: string } | null>(null);

  async function reset(u: UserRow) {
    if (!window.confirm(t("admin.newSetupLinkConfirm", { name: u.name || u.email }))) return;
    const res = await adminResetUserAction(u.id);
    if (!res.ok) return toast.error(res.message);
    setLink({ title: t("admin.setupLinkCreated"), url: res.data.setupUrl });
    router.refresh();
  }

  async function remove(u: UserRow) {
    if (!window.confirm(t("admin.deleteUserConfirm", { name: u.name || u.email }))) return;
    const res = await adminDeleteUserAction(u.id);
    if (!res.ok) return toast.error(res.message);
    toast.success(t("admin.userDeleted"));
    router.refresh();
  }

  return (
    <div className="space-y-4">
      <Button onClick={() => setEditing("new")}><Plus className="size-4" /> {t("admin.newUser")}</Button>
      <Card>
        <CardContent className="p-0">
          <ul className="divide-y">
            {users.map((u) => (
              <li key={u.id} className="flex flex-col gap-2 p-4 sm:flex-row sm:items-center">
                <div className="min-w-0 flex-1">
                  <p className="flex items-center gap-1.5 truncate font-medium">
                    {u.isAdmin && <ShieldCheck className="size-4 shrink-0 text-primary" aria-label={t("admin.isAdmin")} />}
                    {u.name || u.email}
                    {u.id === selfId && <span className="font-normal text-muted-foreground">({t("admin.you")})</span>}
                  </p>
                  <p className="truncate text-xs text-muted-foreground">
                    {[
                      u.name ? u.email : null,
                      u.onboardingStep === "SET_CREDENTIALS" ? t("admin.pending") : null,
                      t("admin.passkeyCount", { count: u.passkeyCount }),
                      u.hasPassword ? t("admin.withPassword") : null,
                      t("admin.familyCount", { count: u.familyCount }),
                    ].filter(Boolean).join(" · ")}
                  </p>
                </div>
                <div className="flex gap-1">
                  <Button variant="ghost" size="icon" aria-label={t("common.rename")} onClick={() => setEditing(u)}><Pencil className="size-4" /></Button>
                  <Button variant="ghost" size="icon" aria-label={t("admin.newSetupLink")} title={t("admin.newSetupLink")} onClick={() => reset(u)}><Link2 className="size-4" /></Button>
                  {u.id !== selfId && (
                    <Button variant="ghost" size="icon" aria-label={t("admin.deleteUser")} className="text-destructive hover:bg-destructive/10 hover:text-destructive" onClick={() => remove(u)}>
                      <Trash2 className="size-4" />
                    </Button>
                  )}
                </div>
              </li>
            ))}
          </ul>
        </CardContent>
      </Card>

      {editing && (
        <UserDialog
          user={editing === "new" ? null : editing}
          isSelf={editing !== "new" && editing.id === selfId}
          onClose={() => setEditing(null)}
          onCreated={(url) => setLink({ title: t("admin.userCreated"), url })}
        />
      )}

      <Dialog open={link !== null} onOpenChange={(open) => !open && setLink(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t("admin.setupLink")}</DialogTitle>
            <DialogDescription>{link?.title}</DialogDescription>
          </DialogHeader>
          <div className="flex gap-2">
            <Input readOnly value={link?.url ?? ""} className="font-mono text-xs" onFocus={(e) => e.target.select()} />
            <Button variant="outline" onClick={() => link && copyText(link.url, t("common.copied"))}><Copy className="size-4" /></Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function UserDialog({
  user,
  isSelf,
  onClose,
  onCreated,
}: {
  user: UserRow | null;
  isSelf: boolean;
  onClose: () => void;
  onCreated: (url: string) => void;
}) {
  const { t } = useT();
  const router = useRouter();
  const [email, setEmail] = useState(user?.email ?? "");
  const [name, setName] = useState(user?.name ?? "");
  const [isAdmin, setIsAdmin] = useState(user?.isAdmin ?? false);
  const [busy, setBusy] = useState(false);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    if (user) {
      const res = await adminUpdateUserAction(user.id, { email, name, isAdmin });
      setBusy(false);
      if (!res.ok) return toast.error(res.message);
      toast.success(t("admin.userSaved"));
    } else {
      const res = await adminCreateUserAction({ email, name, isAdmin });
      setBusy(false);
      if (!res.ok) return toast.error(res.message);
      onCreated(res.data.setupUrl);
    }
    onClose();
    router.refresh();
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{user ? user.name || user.email : t("admin.newUser")}</DialogTitle>
          {!user && <DialogDescription>{t("admin.newUserHint")}</DialogDescription>}
        </DialogHeader>
        <form onSubmit={save} className="space-y-3">
          <div className="space-y-1.5">
            <Label htmlFor="u-email">{t("admin.email")}</Label>
            <Input id="u-email" required value={email} onChange={(e) => setEmail(e.target.value)} />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="u-name">{t("admin.name")}</Label>
            <Input id="u-name" value={name} maxLength={100} onChange={(e) => setName(e.target.value)} />
          </div>
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" className="size-4" checked={isAdmin} disabled={isSelf} onChange={(e) => setIsAdmin(e.target.checked)} />
            {t("admin.isAdmin")}
          </label>
          <Button type="submit" className="w-full" disabled={busy || !email.trim()}>
            {user ? t("common.save") : t("common.create")}
          </Button>
        </form>
      </DialogContent>
    </Dialog>
  );
}
