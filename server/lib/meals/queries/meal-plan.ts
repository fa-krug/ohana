import { and, asc, desc, eq, inArray } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { mealPlanEntries, mealPlanExcludedTags, mealPlans, planIterations, recipes } from "@/lib/db/schema";
import { iterationShoppingDates, planShoppingDays } from "../shopping/needs";

export interface PlanEntryDto {
  id: string; date: string; mealType: string; recipeId: string; recipeTitle: string;
  servings: number; isLeftover: boolean; sourceEntryId: string | null; isLocked: boolean;
}
export interface PlanIterationDto {
  id: string; startDate: string; endDate: string; status: string;
  /** The iteration's shopping days (what each needs: GET /meals/shopping). */
  entries: PlanEntryDto[]; shoppingDates: string[]; createdAt: Date;
}
export interface MealPlanView {
  id: string; iterationWeeks: number; shoppingDays: number[]; servings: number;
  knownRatio: string; defaultLeftoverDays: number; excludedTagIds: string[];
  iterations: PlanIterationDto[]; createdAt: Date;
}

export function getMealPlanView(db: Db, familyId: string): MealPlanView | null {
  const plan = db.select().from(mealPlans).where(eq(mealPlans.familyId, familyId)).get();
  if (!plan) return null;

  const excludedTagIds = db
    .select({ tagId: mealPlanExcludedTags.tagId })
    .from(mealPlanExcludedTags)
    .where(eq(mealPlanExcludedTags.mealPlanId, plan.id))
    .all()
    .map((r) => r.tagId);

  const iterationRows = db
    .select()
    .from(planIterations)
    .where(eq(planIterations.mealPlanId, plan.id))
    .all();
  const iterationIds = iterationRows.map((i) => i.id);

  const entryRows = iterationIds.length
    ? db
        .select({
          id: mealPlanEntries.id, iterationId: mealPlanEntries.iterationId, date: mealPlanEntries.date,
          mealType: mealPlanEntries.mealType, recipeId: mealPlanEntries.recipeId,
          recipeTitle: recipes.title, servings: mealPlanEntries.servings,
          isLeftover: mealPlanEntries.isLeftover, sourceEntryId: mealPlanEntries.sourceEntryId,
          isLocked: mealPlanEntries.isLocked,
        })
        .from(mealPlanEntries)
        .innerJoin(recipes, eq(recipes.id, mealPlanEntries.recipeId))
        .where(inArray(mealPlanEntries.iterationId, iterationIds))
        .orderBy(asc(mealPlanEntries.date))
        .all()
    : [];
  const entriesByIteration = new Map<string, PlanEntryDto[]>();
  for (const e of entryRows) {
    const list = entriesByIteration.get(e.iterationId) ?? [];
    list.push({
      id: e.id, date: e.date, mealType: e.mealType, recipeId: e.recipeId, recipeTitle: e.recipeTitle,
      servings: e.servings, isLeftover: e.isLeftover, sourceEntryId: e.sourceEntryId, isLocked: e.isLocked,
    });
    entriesByIteration.set(e.iterationId, list);
  }

  const shoppingDays = planShoppingDays(plan);

  const iterations: PlanIterationDto[] = iterationRows
    .map((i) => ({
      id: i.id, startDate: i.startDate, endDate: i.endDate, status: i.status,
      entries: entriesByIteration.get(i.id) ?? [],
      shoppingDates: iterationShoppingDates(i.startDate, i.endDate, shoppingDays),
      createdAt: i.createdAt,
    }))
    .sort((a, b) => {
      // ACTIVE first, then startDate descending, then createdAt descending (tiebreak)
      if (a.status !== b.status) return a.status === "ACTIVE" ? -1 : 1;
      if (a.startDate !== b.startDate) return a.startDate < b.startDate ? 1 : -1;
      return +b.createdAt - +a.createdAt;
    });

  return {
    id: plan.id, iterationWeeks: plan.iterationWeeks, shoppingDays, servings: plan.servings,
    knownRatio: plan.knownRatio, defaultLeftoverDays: plan.defaultLeftoverDays, excludedTagIds,
    iterations, createdAt: plan.createdAt,
  };
}

export interface MealsSummary {
  /** Today's (lunch) entry of the family's plan, if any. */
  today: { recipeId: string; recipeTitle: string; isLeftover: boolean } | null;
}

/** What the family overview shows of the meals module. */
export function getMealsSummary(db: Db, familyId: string, todayIso: string): MealsSummary {
  const today =
    db
      .select({ recipeId: mealPlanEntries.recipeId, recipeTitle: recipes.title, isLeftover: mealPlanEntries.isLeftover })
      .from(mealPlanEntries)
      .innerJoin(planIterations, eq(planIterations.id, mealPlanEntries.iterationId))
      .innerJoin(mealPlans, eq(mealPlans.id, planIterations.mealPlanId))
      .innerJoin(recipes, eq(recipes.id, mealPlanEntries.recipeId))
      .where(and(eq(mealPlans.familyId, familyId), eq(mealPlanEntries.date, todayIso)))
      .orderBy(desc(planIterations.createdAt))
      .get() ?? null;

  return { today };
}
