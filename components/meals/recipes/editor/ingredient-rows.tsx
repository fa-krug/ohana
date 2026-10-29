"use client";

import { useState } from "react";
import { useFormContext, useFieldArray } from "react-hook-form";
import { useT } from "@/lib/i18n/provider";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import type { RecipeFormValues } from "@/lib/meals/schemas/recipe";
import type { IngredientLite, UnitLite } from "@/lib/meals/queries/recipes";
import type { Locale } from "@/lib/i18n/config";

function ingredientName(i: IngredientLite, locale: Locale) {
  return locale === "de" ? i.nameDe : i.nameEn;
}

// ---------------------------------------------------------------------------
// Per-row sub-component — owns its own search query & display name state so
// that typing in one row does NOT show suggestions in every other row.
// ---------------------------------------------------------------------------

interface IngredientRowProps {
  index: number;
  fieldId: string;
  ingredients: IngredientLite[];
  units: UnitLite[];
  locale: Locale;
  onRemove: () => void;
}

function IngredientRow({ index, fieldId, ingredients, units, locale, onRemove }: IngredientRowProps) {
  const { t } = useT();
  const { register, setValue, getValues } = useFormContext<RecipeFormValues>();

  // Seed display name: prefer the name from the ingredients list (edit-mode
  // rows have an ingredientId but empty nameEn/nameDe by design), fall back
  // to the typed nameEn for new / auto-create rows.
  const seedDisplayName = (): string => {
    const id = getValues(`ingredients.${index}.ingredientId`);
    if (id != null) {
      const found = ingredients.find((i) => i.id === id);
      if (found) return ingredientName(found, locale);
    }
    return getValues(`ingredients.${index}.nameEn`) ?? "";
  };

  const [query, setQuery] = useState<string>(seedDisplayName);
  // Suggestions show while typing; picking one (or leaving the field) closes them.
  const [open, setOpen] = useState(false);

  const matches = open && query.trim()
    ? ingredients
        .filter((i) => ingredientName(i, locale).toLowerCase().includes(query.toLowerCase()))
        .sort((a, b) => ingredientName(a, locale).localeCompare(ingredientName(b, locale), locale))
        .slice(0, 6)
    : [];

  return (
    <div key={fieldId} className="flex flex-wrap items-center gap-2 rounded-md border p-2">
      <div className="relative min-w-[10rem] flex-1">
        <Input
          value={query}
          placeholder={t("meals.ingredients.searchPlaceholder")}
          onBlur={() => setTimeout(() => setOpen(false), 150)}
          onKeyDown={(e) => {
            if (e.key === "Escape") setOpen(false);
          }}
          onChange={(e) => {
            const v = e.target.value;
            setQuery(v);
            setOpen(true);
            // Unmatched free-text: clear the linked ingredient id, store text
            // in both name fields so it survives serialisation.
            setValue(`ingredients.${index}.ingredientId`, null);
            setValue(`ingredients.${index}.nameEn`, v);
            setValue(`ingredients.${index}.nameDe`, v);
          }}
        />
        {matches.length > 0 && (
          <ul className="absolute z-10 mt-1 w-full rounded-md border bg-popover shadow">
            {matches.map((m) => (
              <li key={m.id}>
                <button
                  type="button"
                  className="block w-full px-2 py-1 text-left text-sm hover:bg-accent"
                  onClick={() => {
                    setValue(`ingredients.${index}.ingredientId`, m.id);
                    setValue(`ingredients.${index}.nameEn`, m.nameEn);
                    setValue(`ingredients.${index}.nameDe`, m.nameDe);
                    setQuery(ingredientName(m, locale));
                    setOpen(false);
                  }}
                >
                  {ingredientName(m, locale)}
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
      <Input
        className="w-20"
        placeholder={t("meals.ingredients.quantity")}
        {...register(`ingredients.${index}.quantity`)}
      />
      <select
        className="h-9 rounded-md border border-input bg-background pl-3 pr-9 text-sm"
        {...register(`ingredients.${index}.unitId`, { valueAsNumber: true })}
      >
        {units.map((u) => (
          <option key={u.id} value={u.id}>
            {u.abbreviation}
          </option>
        ))}
      </select>
      <Button type="button" variant="ghost" onClick={onRemove}>
        {t("meals.common.remove")}
      </Button>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Public component
// ---------------------------------------------------------------------------

export function IngredientRows({
  ingredients,
  units,
  locale,
}: {
  ingredients: IngredientLite[];
  units: UnitLite[];
  locale: Locale;
}) {
  const { t } = useT();
  const { control } = useFormContext<RecipeFormValues>();
  const { fields, append, remove } = useFieldArray({ control, name: "ingredients" });

  return (
    <section className="space-y-3">
      <h2 className="text-sm font-medium">{t("meals.ingredients.title")}</h2>
      {fields.map((field, idx) => (
        <IngredientRow
          key={field.id}
          fieldId={field.id}
          index={idx}
          ingredients={ingredients}
          units={units}
          locale={locale}
          onRemove={() => remove(idx)}
        />
      ))}
      <Button
        type="button"
        variant="outline"
        onClick={() =>
          append({
            ingredientId: null,
            nameEn: "",
            nameDe: "",
            quantity: "",
            unitId: units[0]?.id ?? 1,
          })
        }
      >
        {t("meals.ingredients.add")}
      </Button>
    </section>
  );
}
