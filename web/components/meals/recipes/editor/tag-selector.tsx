"use client";

import { useState } from "react";
import { useFormContext } from "react-hook-form";
import { useT } from "@/lib/i18n/provider";
import { toast } from "@/components/ui/sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { createTagAction } from "@/app/actions/meals";
import type { RecipeFormValues } from "@/lib/meals/schemas/recipe";
import type { RecipeTagDto } from "@/lib/meals/queries/recipes";
import type { Locale } from "@/lib/i18n/config";
import { useMeals } from "../../meals-context";

const CATEGORIES = ["DIETARY", "PROTEIN", "CUISINE", "MEAL_TYPE"] as const;

export function TagSelector({ tags, locale }: { tags: RecipeTagDto[]; locale: Locale }) {
  const { t } = useT();
  const { familyId } = useMeals();
  const { watch, setValue } = useFormContext<RecipeFormValues>();
  const selected = watch("tagIds");
  const [localTags, setLocalTags] = useState<RecipeTagDto[]>(tags);
  const [creating, setCreating] = useState(false);
  const [newCat, setNewCat] = useState<string>("CUISINE");
  const [newEn, setNewEn] = useState("");
  const [newDe, setNewDe] = useState("");

  const tagName = (tag: RecipeTagDto) => (locale === "de" ? tag.nameDe : tag.nameEn);

  function toggle(id: string) {
    setValue("tagIds", selected.includes(id) ? selected.filter((x) => x !== id) : [...selected, id]);
  }

  async function create() {
    if (!newEn.trim() || !newDe.trim()) return;
    const dup = localTags.some(
      (tg) => tg.category === newCat && tg.nameEn.toLowerCase() === newEn.trim().toLowerCase(),
    );
    if (dup) {
      toast.error(t("meals.tags.duplicate"));
      return;
    }
    setCreating(true);
    const res = await createTagAction(familyId, { category: newCat, nameEn: newEn.trim(), nameDe: newDe.trim() });
    setCreating(false);
    if (!res.ok) {
      toast.error(res.message || t("meals.common.error"));
      return;
    }
    const created: RecipeTagDto = { id: res.data.id, category: newCat, nameEn: newEn.trim(), nameDe: newDe.trim() };
    setLocalTags([...localTags, created]);
    setValue("tagIds", [...selected, created.id]);
    setNewEn("");
    setNewDe("");
  }

  return (
    <section className="space-y-3">
      <h2 className="text-sm font-medium">{t("meals.tags.title")}</h2>
      {CATEGORIES.map((cat) => {
        const inCat = localTags.filter((tg) => tg.category === cat);
        if (inCat.length === 0) return null;
        return (
          <div key={cat} className="space-y-1">
            <p className="text-xs uppercase text-muted-foreground">{t(`meals.tags.categories.${cat}`)}</p>
            <div className="flex flex-wrap gap-1">
              {inCat.map((tg) => (
                <button
                  key={tg.id}
                  type="button"
                  onClick={() => toggle(tg.id)}
                  className={`rounded-full border px-2 py-0.5 text-sm ${selected.includes(tg.id) ? "bg-primary text-primary-foreground" : ""}`}
                >
                  {tagName(tg)}
                </button>
              ))}
            </div>
          </div>
        );
      })}
      <div className="flex flex-wrap items-end gap-2 rounded-md border p-2">
        <select
          className="h-9 rounded-md border border-input bg-background pl-3 pr-9 text-sm"
          value={newCat}
          onChange={(e) => setNewCat(e.target.value)}
        >
          {CATEGORIES.map((c) => (
            <option key={c} value={c}>
              {t(`meals.tags.categories.${c}`)}
            </option>
          ))}
        </select>
        <Input
          className="w-32"
          placeholder={t("meals.tags.nameEn")}
          value={newEn}
          onChange={(e) => setNewEn(e.target.value)}
        />
        <Input
          className="w-32"
          placeholder={t("meals.tags.nameDe")}
          value={newDe}
          onChange={(e) => setNewDe(e.target.value)}
        />
        <Button type="button" variant="outline" disabled={creating} onClick={create}>
          {t("meals.tags.create")}
        </Button>
      </div>
    </section>
  );
}
