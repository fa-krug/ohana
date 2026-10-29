"use client";

import { useForm, FormProvider } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { useT } from "@/lib/i18n/provider";
import { toast } from "@/components/ui/sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { recipeFormSchema, type RecipeFormValues } from "@/lib/meals/schemas/recipe";
import { buildPayload } from "./editor/build-payload";
import { IngredientRows } from "./editor/ingredient-rows";
import { StepEditor } from "./editor/step-editor";
import { TagSelector } from "./editor/tag-selector";
import { saveRecipeAction } from "@/app/actions/meals";
import type { IngredientLite, UnitLite, RecipeTagDto } from "@/lib/meals/queries/recipes";
import type { Locale } from "@/lib/i18n/config";
import { useMeals } from "../meals-context";

const EMPTY: RecipeFormValues = {
  title: "", description: "", defaultServings: 2,
  prepTimeMinutes: null, cookTimeMinutes: null, leftoverDays: null,
  ingredients: [], manualSteps: [], machineSteps: [], tagIds: [],
};

export function RecipeEditor(props: {
  mode: "create" | "edit";
  recipeId: string | null;
  listType: "KNOWN" | "TO_TRY";
  initialValues?: RecipeFormValues;
  ingredients: IngredientLite[];
  units: UnitLite[];
  tags: RecipeTagDto[];
  locale: Locale;
}) {
  const { t } = useT();
  const { familyId, base } = useMeals();
  const router = useRouter();
  const [saving, setSaving] = useState(false);
  const form = useForm<RecipeFormValues>({
    resolver: zodResolver(recipeFormSchema),
    defaultValues: props.initialValues ?? EMPTY,
  });

  async function onSubmit(values: RecipeFormValues) {
    setSaving(true);
    const res = await saveRecipeAction(familyId, props.recipeId, buildPayload(values, props.listType));
    setSaving(false);
    if (!res.ok) {
      toast.error(res.message || t("meals.common.error"));
      return;
    }
    toast.success(t(props.mode === "create" ? "meals.recipes.created" : "meals.recipes.saved"));
    if (props.mode === "create") {
      router.push(`${base}/recipes?list=${props.listType}&new=${res.data.id}`);
    } else {
      router.push(`${base}/recipes/${res.data.id}`);
    }
  }

  return (
    <FormProvider {...form}>
      <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-6">
        <h1 className="text-xl font-semibold">
          {t(props.mode === "create" ? "meals.recipes.newRecipe" : "meals.recipes.editRecipe")}
        </h1>

        <div className="space-y-2">
          <label className="text-sm font-medium">{t("meals.recipes.recipeName")}</label>
          <Input {...form.register("title")} placeholder={t("meals.recipes.titlePlaceholder")} />
          {form.formState.errors.title && (
            <p className="text-sm text-destructive">{t("meals.recipes.titleRequired")}</p>
          )}
        </div>

        <div className="space-y-2">
          <label className="text-sm font-medium">{t("meals.recipes.description")}</label>
          <textarea
            {...form.register("description")}
            className="w-full rounded-md border border-input bg-transparent px-3 py-2 text-base shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring md:text-sm"
            rows={3}
          />
        </div>

        <div className="grid grid-cols-3 gap-3">
          <div className="space-y-2">
            <label className="text-sm font-medium">{t("meals.recipes.servings")}</label>
            <Input type="number" min={1} {...form.register("defaultServings", { valueAsNumber: true })} />
          </div>
          <div className="space-y-2">
            <label className="text-sm font-medium">{t("meals.recipes.prepTime")}</label>
            <Input type="number" min={0} {...form.register("prepTimeMinutes", { setValueAs: (v) => (v === "" || v == null ? null : Number(v)) })} />
          </div>
          <div className="space-y-2">
            <label className="text-sm font-medium">{t("meals.recipes.cookTime")}</label>
            <Input type="number" min={0} {...form.register("cookTimeMinutes", { setValueAs: (v) => (v === "" || v == null ? null : Number(v)) })} />
          </div>
        </div>

        <IngredientRows ingredients={props.ingredients} units={props.units} locale={props.locale} />

        <StepEditor method="manual" ingredients={props.ingredients} units={props.units} locale={props.locale} />
        <StepEditor method="machine" ingredients={props.ingredients} units={props.units} locale={props.locale} />

        <TagSelector tags={props.tags} locale={props.locale} />

        <div className="flex gap-2">
          <Button type="submit" disabled={saving}>
            {saving ? t("meals.common.saving") : t("meals.common.save")}
          </Button>
          <Button type="button" variant="outline" onClick={() => router.back()}>
            {t("meals.common.cancel")}
          </Button>
        </div>
      </form>
    </FormProvider>
  );
}
