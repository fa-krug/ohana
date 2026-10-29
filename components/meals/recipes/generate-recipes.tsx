"use client";

// The recipe generator (port of cookless's generate-recipes-client.tsx): how many recipes,
// tags they must match, extra wishes, photos (only with an image model); the recipes stream in
// (lib/meals/ai/stream-client.ts), the user picks which to keep and saves them to "Want to try".

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ArrowLeft, ImageIcon, Loader2, Sparkles, Square } from "lucide-react";
import { useT } from "@/lib/i18n/provider";
import { pickName } from "@/lib/meals/display/format";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";
import { toast } from "@/components/ui/sonner";
import type { RecipeTagDto } from "@/lib/meals/queries/recipes";
import { type GeneratedRecipeData, streamGenerateRecipes } from "@/lib/meals/ai/stream-client";
import type { BulkRecipeInput } from "@/lib/meals/recipes/bulk-create";
import { bulkCreateRecipesAction } from "@/app/actions/meals";
import { useMeals } from "../meals-context";

interface PreviewRecipe {
  data: GeneratedRecipeData;
  imageBase64?: string;
  selected: boolean;
}

export function toBulkInput(r: PreviewRecipe): BulkRecipeInput {
  const d = r.data;
  return {
    title: d.title,
    description: d.description ?? "",
    defaultServings: d.default_servings ?? 2,
    prepTimeMinutes: d.prep_time_minutes ?? null,
    cookTimeMinutes: d.cook_time_minutes ?? null,
    leftoverDays: d.leftover_days ?? null,
    ingredients: (d.ingredients ?? []).map((i, idx) => ({
      nameEn: i.name_en,
      nameDe: i.name_de,
      category: i.category ?? "OTHER",
      quantity: String(i.quantity ?? "0"),
      unitAbbreviation: i.unit_abbreviation ?? "",
      order: i.order ?? idx,
    })),
    manualSteps: (d.manual_steps ?? []).map((s) => ({ stepNumber: s.step_number, instruction: s.instruction ?? "" })),
    machineSteps: (d.machine_steps ?? []).map((s) => ({
      stepNumber: s.step_number,
      instruction: s.instruction ?? "",
      programType: s.program_type,
      temperature: s.temperature ?? null,
      durationSeconds: s.duration_seconds ?? null,
      speed: s.speed ?? null,
      turbo: s.turbo,
      direction: s.direction,
      weightGrams: s.weight_grams ?? null,
    })),
    tagIds: d.tag_ids ?? [],
    imageBase64: r.imageBase64 ?? null,
  };
}

export function GenerateRecipes({ tags, locale, photos }: { tags: RecipeTagDto[]; locale: string; photos: boolean }) {
  const { t } = useT();
  const { familyId, base } = useMeals();
  const router = useRouter();
  const [count, setCount] = useState(5);
  const [selectedTagIds, setSelectedTagIds] = useState<string[]>([]);
  const [freeText, setFreeText] = useState("");
  const [generateImages, setGenerateImages] = useState(photos);
  const [recipes, setRecipes] = useState<PreviewRecipe[]>([]);
  const [generating, setGenerating] = useState(false);
  const [ran, setRan] = useState(false);
  const [saving, setSaving] = useState(false);
  const abortRef = useRef<AbortController | null>(null);

  useEffect(() => () => abortRef.current?.abort(), []);

  async function onGenerate() {
    setRecipes([]);
    setGenerating(true);
    setRan(true);
    const ctrl = new AbortController();
    abortRef.current = ctrl;
    try {
      await streamGenerateRecipes(
        familyId,
        { count, tagIds: selectedTagIds, freeText, generateImages: photos && generateImages },
        (e) => {
          if (e.type === "recipe") {
            setRecipes((prev) => {
              const next = [...prev];
              next[e.index] = { data: e.data, selected: true };
              return next;
            });
          } else if (e.type === "image") {
            setRecipes((prev) => {
              const next = [...prev];
              if (next[e.index]) next[e.index] = { ...next[e.index], imageBase64: e.data.image_base64 };
              return next;
            });
          } else if (e.type === "error") {
            toast.error(t("meals.generate.failed", { msg: e.message }));
          } else if (e.type === "image_error") {
            toast.error(t("meals.generate.photosFailed", { msg: e.message }));
          }
        },
        ctrl.signal,
      );
    } catch (err) {
      if ((err as Error).name !== "AbortError") toast.error(t("meals.generate.failed", { msg: (err as Error).message }));
    } finally {
      setGenerating(false);
      abortRef.current = null;
    }
  }

  async function onSave() {
    const chosen = recipes.filter((r) => r?.selected);
    if (!chosen.length) return;
    setSaving(true);
    const res = await bulkCreateRecipesAction(familyId, { recipes: chosen.map(toBulkInput) });
    setSaving(false);
    if (res.ok) {
      toast.success(t("meals.generate.saved", { count: res.data.createdIds.length }));
      router.push(`${base}/recipes?list=TO_TRY`);
      router.refresh();
    } else {
      toast.error(res.message || t("meals.common.errorRetry"));
    }
  }

  const present = recipes.filter(Boolean);
  const selectedCount = present.filter((r) => r.selected).length;
  const waitingForPhotos = generating && photos && generateImages && present.length > 0;

  return (
    <div className="mx-auto flex w-full max-w-2xl flex-col gap-5">
      <div className="flex items-center gap-2">
        <Button asChild variant="ghost" size="icon" aria-label={t("meals.generate.back")}>
          <Link href={`${base}/recipes`}>
            <ArrowLeft />
          </Link>
        </Button>
        <h1 className="text-2xl font-bold">{t("meals.generate.title")}</h1>
      </div>

      <div className="space-y-4 rounded-xl border bg-card p-4">
        <div className="space-y-1.5">
          <Label htmlFor="gen-count">{t("meals.generate.count")}</Label>
          <Input
            id="gen-count"
            type="number"
            inputMode="numeric"
            min={1}
            max={20}
            value={count}
            className="w-24"
            onChange={(e) => setCount(Math.min(20, Math.max(1, Number(e.target.value) || 1)))}
          />
        </div>

        {tags.length > 0 && (
          <fieldset className="space-y-1.5">
            <legend className="text-sm font-medium">{t("meals.generate.tags")}</legend>
            <div className="flex flex-wrap gap-1.5">
              {tags.map((tag) => {
                const checked = selectedTagIds.includes(tag.id);
                return (
                  <button
                    key={tag.id}
                    type="button"
                    aria-pressed={checked}
                    onClick={() => setSelectedTagIds((ids) => (checked ? ids.filter((x) => x !== tag.id) : [...ids, tag.id]))}
                    className={`rounded-full border px-2.5 py-1 text-xs transition-colors ${
                      checked ? "border-primary bg-primary text-primary-foreground" : "border-border hover:bg-muted"
                    }`}
                  >
                    {pickName(locale, tag)}
                  </button>
                );
              })}
            </div>
          </fieldset>
        )}

        <div className="space-y-1.5">
          <Label htmlFor="gen-text">{t("meals.generate.freeText")}</Label>
          <Textarea
            id="gen-text"
            rows={3}
            maxLength={2000}
            value={freeText}
            placeholder={t("meals.generate.freeTextPlaceholder")}
            onChange={(e) => setFreeText(e.target.value)}
          />
        </div>

        {photos ? (
          <div className="flex items-center gap-2">
            <Switch id="gen-photos" checked={generateImages} onCheckedChange={setGenerateImages} />
            <Label htmlFor="gen-photos">{t("meals.generate.generateImages")}</Label>
          </div>
        ) : null}

        {generating ? (
          <Button variant="outline" onClick={() => abortRef.current?.abort()} className="w-full">
            <Square size={16} />
            {t("meals.generate.stop")}
          </Button>
        ) : (
          <Button onClick={onGenerate} className="w-full">
            <Sparkles size={16} />
            {t("meals.generate.generate")}
          </Button>
        )}
        {generating && (
          <p className="flex items-center gap-2 text-sm text-muted-foreground">
            <Loader2 size={14} className="animate-spin" />
            {waitingForPhotos ? t("meals.generate.generatingImages") : t("meals.generate.generating")}
          </p>
        )}
      </div>

      {present.length > 0 && (
        <div className="space-y-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span className="text-sm text-muted-foreground">{t("meals.generate.selected", { count: selectedCount })}</span>
            <Button onClick={onSave} disabled={saving || selectedCount === 0 || generating}>
              {saving && <Loader2 size={16} className="animate-spin" />}
              {t("meals.generate.saveCount", { count: selectedCount })}
            </Button>
          </div>
          {present.map((r) => {
            const idx = recipes.indexOf(r);
            const ings = r.data.ingredients ?? [];
            return (
              <div key={idx} className="flex gap-3 rounded-lg border bg-card p-3">
                <Checkbox
                  className="mt-1"
                  checked={r.selected}
                  aria-label={r.data.title}
                  onCheckedChange={(v) =>
                    setRecipes((prev) => {
                      const next = [...prev];
                      if (next[idx]) next[idx] = { ...next[idx], selected: v === true };
                      return next;
                    })
                  }
                />
                {r.imageBase64 ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img src={`data:image/webp;base64,${r.imageBase64}`} alt="" className="size-16 shrink-0 rounded-md object-cover" />
                ) : (
                  <div className="flex size-16 shrink-0 items-center justify-center rounded-md bg-muted">
                    <ImageIcon size={20} className={`text-muted-foreground ${waitingForPhotos ? "animate-pulse" : ""}`} />
                  </div>
                )}
                <details className="min-w-0 flex-1">
                  <summary className="cursor-pointer list-none">
                    <p className="font-medium [overflow-wrap:anywhere]">{r.data.title}</p>
                    <p className="text-xs text-muted-foreground">
                      {t("meals.generate.meta", {
                        ingredients: ings.length,
                        servings: r.data.default_servings ?? 2,
                        minutes: (r.data.prep_time_minutes ?? 0) + (r.data.cook_time_minutes ?? 0),
                      })}
                    </p>
                  </summary>
                  {r.data.description ? <p className="mt-2 text-sm">{r.data.description}</p> : null}
                  <ul className="mt-2 list-disc pl-5 text-sm">
                    {ings.map((i, k) => (
                      <li key={k}>
                        {String(i.quantity ?? "")} {i.unit_abbreviation} {locale === "de" ? i.name_de : i.name_en}
                      </li>
                    ))}
                  </ul>
                  <ol className="mt-2 list-decimal space-y-1 pl-5 text-sm">
                    {(r.data.manual_steps ?? []).map((s, k) => (
                      <li key={k}>{s.instruction}</li>
                    ))}
                  </ol>
                </details>
              </div>
            );
          })}
        </div>
      )}

      {ran && !generating && present.length === 0 && (
        <p className="text-sm text-muted-foreground">{t("meals.generate.noResults")}</p>
      )}
    </div>
  );
}
