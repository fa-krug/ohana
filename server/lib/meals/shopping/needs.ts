// What the meal plan needs from the shops, per shopping day, computed live from the plan (no
// shopping list is stored: the app writes these items into the user's Reminders list). Each
// iteration's days are split into segments, one per shopping day (computeShoppingSegments);
// a shopping day needs the ingredients of the segment's meals (not the leftovers), scaled to
// their servings and summed per ingredient and base unit (aggregateShoppingItems).

import { and, eq, inArray } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { ingredients, mealPlanEntries, mealPlans, planIterations, recipeIngredients, recipes, units } from "@/lib/db/schema";
import { computeShoppingSegments } from "@/lib/meals/domain/meal-plan/iteration-dates";
import { aggregateShoppingItems, type ShoppingEntry } from "@/lib/meals/domain/shopping/aggregate";
import type { DomainUnit } from "@/lib/meals/domain/shopping/units";

export interface ShoppingNeed {
  /** `${ingredientId}-${unitId}`: the same for an ingredient and unit on that day across plan
   *  changes. */
  key: string;
  ingredientId: number;
  name: string;
  /** PRODUCE | DAIRY | MEAT | PANTRY | FROZEN | OTHER */
  category: string;
  /** A decimal, e.g. "150" or "0.5". */
  quantity: string;
  /** The unit's abbreviation. */
  unit: string;
}

export interface ShoppingDay {
  date: string;
  items: ShoppingNeed[];
}

/** The shopping days of an iteration (one per segment). */
export function iterationShoppingDates(startDate: string, endDate: string, shoppingDays: readonly number[]): string[] {
  return computeShoppingSegments(startDate, endDate, [...shoppingDays]).map((s) => s.shoppingDate);
}

/** The plan's weekdays to shop on. */
export function planShoppingDays(plan: { shoppingDay1: number; shoppingDay2: number | null }): number[] {
  return [plan.shoppingDay1, plan.shoppingDay2].filter((d): d is number => d !== null && d !== undefined);
}

/** What the family's meal plan needs on every shopping day from `from` on (days without items
 *  left out), sorted by day; items by name in `locale`. */
export function shoppingNeeds(db: Db, familyId: string, opts: { from: string; locale: "en" | "de" }): ShoppingDay[] {
  const plan = db.select().from(mealPlans).where(eq(mealPlans.familyId, familyId)).get();
  if (!plan) return [];
  const days = planShoppingDays(plan);
  const iterations = db
    .select({ id: planIterations.id, start: planIterations.startDate, end: planIterations.endDate })
    .from(planIterations)
    .where(eq(planIterations.mealPlanId, plan.id))
    .all();

  // The segments still ahead: per iteration, the days whose meals are bought on `shoppingDate`.
  const segments = iterations.flatMap((it) =>
    computeShoppingSegments(it.start, it.end, days)
      .filter((s) => s.shoppingDate >= opts.from)
      .map((s) => ({ ...s, iterationId: it.id })),
  );
  if (!segments.length) return [];

  const entries = db
    .select({
      iterationId: mealPlanEntries.iterationId,
      date: mealPlanEntries.date,
      recipeId: mealPlanEntries.recipeId,
      servings: mealPlanEntries.servings,
      defaultServings: recipes.defaultServings,
    })
    .from(mealPlanEntries)
    .innerJoin(recipes, eq(mealPlanEntries.recipeId, recipes.id))
    .where(
      and(
        inArray(mealPlanEntries.iterationId, [...new Set(segments.map((s) => s.iterationId))]),
        eq(mealPlanEntries.isLeftover, false),
      ),
    )
    .all();
  if (!entries.length) return [];

  const unitRows = db.select().from(units).all();
  const unitMap = new Map<number, DomainUnit>(
    unitRows.map((u) => [u.id, { id: u.id, baseUnitId: u.baseUnitId, conversionFactor: u.conversionFactor }]),
  );
  const abbreviation = new Map(unitRows.map((u) => [u.id, u.abbreviation]));
  const recipeIds = [...new Set(entries.map((e) => e.recipeId))];
  const ingredientsOf = new Map<string, { ingredientId: number; quantity: string; unitId: number }[]>();
  for (const ri of db
    .select({
      recipeId: recipeIngredients.recipeId,
      ingredientId: recipeIngredients.ingredientId,
      quantity: recipeIngredients.quantity,
      unitId: recipeIngredients.unitId,
    })
    .from(recipeIngredients)
    .where(inArray(recipeIngredients.recipeId, recipeIds))
    .all()) {
    ingredientsOf.set(ri.recipeId, [...(ingredientsOf.get(ri.recipeId) ?? []), ri]);
  }

  // The meals per shopping day (two iterations' segments on one day go together).
  const byDate = new Map<string, ShoppingEntry[]>();
  for (const seg of segments) {
    const list = byDate.get(seg.shoppingDate) ?? [];
    for (const e of entries) {
      if (e.iterationId !== seg.iterationId || e.date < seg.segStart || e.date > seg.segEnd) continue;
      list.push({
        servings: e.servings,
        defaultServings: e.defaultServings,
        isLeftover: false,
        ingredients: (ingredientsOf.get(e.recipeId) ?? []).map((ri) => ({
          ingredientId: ri.ingredientId,
          quantity: ri.quantity,
          unit: unitMap.get(ri.unitId)!,
        })),
      });
    }
    byDate.set(seg.shoppingDate, list);
  }

  const aggregated = [...byDate].map(([date, list]) => ({ date, items: aggregateShoppingItems(list) }));
  const ingredientIds = [...new Set(aggregated.flatMap((d) => d.items.map((i) => i.ingredientId)))];
  const names = new Map(
    (ingredientIds.length
      ? db
          .select({ id: ingredients.id, nameEn: ingredients.nameEn, nameDe: ingredients.nameDe, category: ingredients.category })
          .from(ingredients)
          .where(inArray(ingredients.id, ingredientIds))
          .all()
      : []
    ).map((i) => [i.id, i]),
  );
  return aggregated
    .filter((d) => d.items.length > 0)
    .sort((a, b) => a.date.localeCompare(b.date))
    .map(({ date, items }) => ({
      date,
      items: items
        .map((a): ShoppingNeed => {
          const ing = names.get(a.ingredientId);
          return {
            key: `${a.ingredientId}-${a.unitId}`,
            ingredientId: a.ingredientId,
            name: (opts.locale === "de" ? ing?.nameDe : ing?.nameEn) ?? "",
            category: ing?.category ?? "OTHER",
            quantity: a.quantity.toString(),
            unit: abbreviation.get(a.unitId) ?? "",
          };
        })
        .sort((x, y) => x.name.localeCompare(y.name, opts.locale) || x.key.localeCompare(y.key)),
    }));
}
