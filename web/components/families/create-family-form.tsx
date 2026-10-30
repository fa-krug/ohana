"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import { createFamilyAction } from "@/app/actions/families";

export function CreateFamilyForm() {
  const { t } = useT();
  const router = useRouter();
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    const res = await createFamilyAction({ name });
    setBusy(false);
    if (!res.ok) return toast.error(res.message);
    toast.success(t("families.created"));
    router.push(`/f/${res.data.id}`);
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <div className="space-y-2">
        <Label htmlFor="family-name">{t("families.nameLabel")}</Label>
        <Input id="family-name" required maxLength={100} placeholder={t("families.namePlaceholder")} value={name} onChange={(e) => setName(e.target.value)} />
      </div>
      <Button type="submit" className="w-full" disabled={busy || !name.trim()}>
        {t("home.createFamily")}
      </Button>
    </form>
  );
}
