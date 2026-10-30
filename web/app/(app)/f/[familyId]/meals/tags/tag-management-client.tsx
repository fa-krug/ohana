"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Pencil, Trash2 } from "lucide-react";
import { useT } from "@/lib/i18n/provider";
import { toast } from "@/components/ui/sonner";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { useConfirm } from "@/components/ui/confirm-dialog";
import { useMeals } from "@/components/meals/meals-context";
import { createTagAction, updateTagAction, deleteTagAction, resetTagsAction } from "@/app/actions/meals";
import type { RecipeTagDto } from "@/lib/meals/queries/recipes";
import type { Locale } from "@/lib/i18n/config";

const CATEGORIES = ["DIETARY", "PROTEIN", "CUISINE", "MEAL_TYPE"] as const;

type Run = (fn: () => Promise<{ ok: boolean; message?: string }>) => Promise<boolean>;

export function TagManagementClient({ tags, locale }: { tags: RecipeTagDto[]; locale: Locale }) {
  const { t } = useT();
  const { familyId, canEdit } = useMeals();
  const router = useRouter();
  const { confirm, dialog } = useConfirm();
  const [busy, setBusy] = useState(false);
  const [newCat, setNewCat] = useState<string>("CUISINE");
  const [newEn, setNewEn] = useState("");
  const [newDe, setNewDe] = useState("");

  const run: Run = async (fn) => {
    setBusy(true);
    const res = await fn();
    setBusy(false);
    if (!res.ok) {
      toast.error(res.message || t("meals.common.error"));
      return false;
    }
    router.refresh();
    return true;
  };

  async function onDelete(tag: RecipeTagDto) {
    const ok = await confirm({
      title: t("meals.tags.deleteTitle"),
      message: t("meals.tags.deleteConfirmPlain"),
      destructive: true,
      confirmLabel: t("meals.common.delete"),
      cancelLabel: t("meals.common.cancel"),
    });
    if (ok) await run(() => deleteTagAction(familyId, tag.id));
  }

  async function onReset() {
    const ok = await confirm({
      title: t("meals.tags.reset"),
      message: t("meals.tags.resetConfirm"),
      destructive: true,
      confirmLabel: t("meals.tags.reset"),
      cancelLabel: t("meals.common.cancel"),
    });
    if (ok) await run(() => resetTagsAction(familyId));
  }

  return (
    <div className="space-y-6">
      <div className="space-y-1">
        <h1 className="text-2xl font-bold">{t("meals.tags.manageTags")}</h1>
        <p className="text-sm text-muted-foreground">{t("meals.tags.subtitle")}</p>
      </div>

      {CATEGORIES.map((cat) => {
        const inCat = tags.filter((tg) => tg.category === cat);
        return (
          <section key={cat} className="space-y-2">
            <h2 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              {t(`meals.tags.categories.${cat}`)}
            </h2>
            <Card>
              <CardContent className="divide-y p-0">
                {inCat.length === 0 && <p className="px-4 py-3 text-sm text-muted-foreground">—</p>}
                {inCat.map((tg) => (
                  <TagRow key={tg.id} tag={tg} locale={locale} busy={busy} canEdit={canEdit} run={run} onDelete={onDelete} />
                ))}
              </CardContent>
            </Card>
          </section>
        );
      })}

      {canEdit && (
        <>
          <section className="space-y-2">
            <h2 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">{t("meals.tags.create")}</h2>
            <div className="grid gap-2 rounded-lg border p-3 sm:grid-cols-[auto_1fr_1fr_auto]">
              <select
                className="h-9 rounded-md border border-input bg-transparent pl-3 pr-9 text-sm"
                value={newCat}
                onChange={(e) => setNewCat(e.target.value)}
                aria-label={t("meals.tags.category")}
              >
                {CATEGORIES.map((c) => (
                  <option key={c} value={c}>
                    {t(`meals.tags.categories.${c}`)}
                  </option>
                ))}
              </select>
              <Input placeholder={t("meals.tags.nameEn")} value={newEn} onChange={(e) => setNewEn(e.target.value)} />
              <Input placeholder={t("meals.tags.nameDe")} value={newDe} onChange={(e) => setNewDe(e.target.value)} />
              <Button
                type="button"
                disabled={busy || !newEn.trim() || !newDe.trim()}
                onClick={async () => {
                  const ok = await run(() =>
                    createTagAction(familyId, { category: newCat, nameEn: newEn.trim(), nameDe: newDe.trim() }),
                  );
                  if (ok) {
                    setNewEn("");
                    setNewDe("");
                  }
                }}
              >
                {t("common.add")}
              </Button>
            </div>
          </section>

          <Button type="button" variant="outline" className="text-destructive" disabled={busy} onClick={onReset}>
            {t("meals.tags.reset")}
          </Button>
        </>
      )}
      {dialog}
    </div>
  );
}

function TagRow({
  tag,
  locale,
  busy,
  canEdit,
  run,
  onDelete,
}: {
  tag: RecipeTagDto;
  locale: Locale;
  busy: boolean;
  canEdit: boolean;
  run: Run;
  onDelete: (tag: RecipeTagDto) => void;
}) {
  const { t } = useT();
  const { familyId } = useMeals();
  const [editing, setEditing] = useState(false);
  const [en, setEn] = useState(tag.nameEn);
  const [de, setDe] = useState(tag.nameDe);

  if (editing) {
    return (
      <div className="flex flex-wrap items-center gap-2 px-4 py-2">
        <Input className="min-w-0 flex-1 basis-32" value={en} onChange={(e) => setEn(e.target.value)} aria-label={t("meals.tags.nameEn")} />
        <Input className="min-w-0 flex-1 basis-32" value={de} onChange={(e) => setDe(e.target.value)} aria-label={t("meals.tags.nameDe")} />
        <div className="flex gap-1">
          <Button
            type="button"
            size="sm"
            disabled={busy}
            onClick={async () => {
              const ok = await run(() => updateTagAction(familyId, tag.id, { nameEn: en.trim(), nameDe: de.trim() }));
              if (ok) setEditing(false);
            }}
          >
            {t("meals.common.save")}
          </Button>
          <Button type="button" size="sm" variant="ghost" onClick={() => setEditing(false)}>
            {t("meals.common.cancel")}
          </Button>
        </div>
      </div>
    );
  }
  return (
    <div className="flex items-center gap-2 px-4 py-1.5">
      <span className="flex-1 py-1.5 text-sm">{locale === "de" ? tag.nameDe : tag.nameEn}</span>
      {canEdit && (
        <>
          <Button type="button" size="icon" variant="ghost" aria-label={t("meals.common.edit")} onClick={() => setEditing(true)}>
            <Pencil className="size-4" />
          </Button>
          <Button
            type="button"
            size="icon"
            variant="ghost"
            className="text-destructive"
            aria-label={t("meals.common.remove")}
            disabled={busy}
            onClick={() => onDelete(tag)}
          >
            <Trash2 className="size-4" />
          </Button>
        </>
      )}
    </div>
  );
}
