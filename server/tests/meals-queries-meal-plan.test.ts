import { describe, expect, it } from "vitest";
import { createTestDb } from "@/lib/test/db";
import {
  families, recipes, mealPlans, planIterations, mealPlanEntries,
  mealPlanExcludedTags, mealTags, ingredients, units,
} from "@/lib/db/schema";
import { getMealPlanView } from "@/lib/meals/queries/meal-plan";

const now = new Date("2026-06-27T12:00:00Z");

function seed() {
  const db = createTestDb();
  db.insert(families).values([
    { id: "h1", feedId: "feedh1", name: "Home", createdAt: now, updatedAt: now },
    { id: "h2", feedId: "feedh2", name: "Other", createdAt: now, updatedAt: now },
  ]).run();
  db.insert(ingredients).values({ id: 1, nameEn: "Tomato", nameDe: "Tomate", category: "PRODUCE" }).run();
  db.insert(units).values({ id: 1, nameEn: "gram", nameDe: "Gramm", abbreviation: "g", conversionFactor: "1" }).run();
  db.insert(mealTags).values({ id: "t1", familyId: "h1", category: "DIETARY", nameEn: "Vegan", nameDe: "Vegan" }).run();
  db.insert(recipes).values([
    { id: "r1", familyId: "h1", title: "Pasta", description: "", listType: "KNOWN", defaultServings: 2, createdAt: now, updatedAt: now },
  ]).run();
  db.insert(mealPlans).values({
    id: "mp1", familyId: "h1", iterationWeeks: 1, shoppingDay1: 0, shoppingDay2: 3,
    servings: 2, knownRatio: "0.7", defaultLeftoverDays: 1, createdAt: now,
  }).run();
  db.insert(mealPlanExcludedTags).values({ mealPlanId: "mp1", tagId: "t1" }).run();
  db.insert(planIterations).values([
    { id: "it_old", mealPlanId: "mp1", startDate: "2026-06-01", endDate: "2026-06-07", status: "ARCHIVED", createdAt: now },
    { id: "it_new", mealPlanId: "mp1", startDate: "2026-06-22", endDate: "2026-06-28", status: "ACTIVE", createdAt: now },
  ]).run();
  db.insert(mealPlanEntries).values({
    id: "e1", iterationId: "it_new", date: "2026-06-22", mealType: "LUNCH",
    recipeId: "r1", servings: 2, isLeftover: false, isLocked: false,
  }).run();
  return db;
}

describe("getMealPlanView", () => {
  it("returns null when the household has no plan", () => {
    expect(getMealPlanView(seed(), "h2")).toBeNull();
  });

  it("recombines shopping days and excluded tags", () => {
    const v = getMealPlanView(seed(), "h1")!;
    expect(v.shoppingDays).toEqual([0, 3]);
    expect(v.excludedTagIds).toEqual(["t1"]);
    expect(v.knownRatio).toBe("0.7");
  });

  it("sorts iterations ACTIVE first then by startDate desc", () => {
    const v = getMealPlanView(seed(), "h1")!;
    expect(v.iterations.map((i) => i.id)).toEqual(["it_new", "it_old"]);
  });

  it("joins recipe titles onto entries", () => {
    const v = getMealPlanView(seed(), "h1")!;
    const active = v.iterations[0]!;
    expect(active.entries[0]!.recipeTitle).toBe("Pasta");
  });

  it("gives each iteration its shopping days", () => {
    const v = getMealPlanView(seed(), "h1")!;
    // Monday and Thursday; 2026-06-22 is a Monday.
    expect(v.iterations[0]!.shoppingDates).toEqual(["2026-06-22", "2026-06-25"]);
    expect(v.iterations[1]!.shoppingDates).toEqual(["2026-06-01", "2026-06-04"]);
  });
});
