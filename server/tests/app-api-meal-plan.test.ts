// The native app's meal plan and shopping routes (lib/meals/app-routes-plan.ts) on the family
// API, signed in with API tokens: viewers read, editors change.

import { and, eq } from "drizzle-orm";
import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import {
  calEntries, calEntryTypes, familyMembers, ingredients, mealPlanEntries, mealPlans, planIterations, recipeIngredients,
  recipes, units,
} from "@/lib/db/schema";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { handleMealPlanApp } from "@/lib/meals/app-routes-plan";
import { handleMeals } from "@/lib/meals/family-routes";
import { setupMealPlan } from "@/lib/meals/meal-plan/setup";
import { mulberry32 } from "@/lib/meals/domain/rng";
import { shoppingNeeds } from "@/lib/meals/shopping/needs";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const BASE = "http://ohana.test/api/v1";
type Res = { status: number; data: any };
type Call = (method: string, path: string, body?: unknown) => Promise<Res>;

let db: Db;
let familyId: string;
let call: Call;
let viewer: Call;
let stranger: Call;

function caller(token: string): Call {
  const handler = createFamilyApi([handleMealPlanApp, handleMeals], { db, appUrl: "http://ohana.test", now: () => NOW });
  return async (method, path, body) => {
    const res = await handler(
      new Request(`${BASE}/families/${familyId}${path}`, {
        method,
        headers: {
          authorization: `Bearer ${token}`,
          ...(body !== undefined ? { "content-type": "application/json" } : {}),
        },
        body: body !== undefined ? JSON.stringify(body) : undefined,
      }),
    );
    return { status: res.status, data: JSON.parse(await res.text()) };
  };
}

const token = (userId: string) => createToken(db, { userId, kind: "api" }, NOW).token;

/** 14 recipes r0…r13 without leftovers, each with its own ingredient (id k+1, "Ing k"). */
function seedRecipes() {
  db.insert(units).values([
    { id: 1, nameEn: "gram", nameDe: "Gramm", abbreviation: "g", conversionFactor: "1" },
    { id: 2, nameEn: "piece", nameDe: "Stück", abbreviation: "Stk", conversionFactor: "1" },
  ]).run();
  for (let k = 0; k < 14; k++) {
    db.insert(ingredients).values({ id: k + 1, nameEn: `Ing ${k}`, nameDe: `Zutat ${k}`, category: "PRODUCE" }).run();
    db.insert(recipes)
      .values({ id: `r${k}`, familyId, title: `Recipe ${k}`, description: "", listType: "KNOWN", defaultServings: 2, leftoverDays: 0, createdAt: NOW, updatedAt: NOW })
      .run();
    db.insert(recipeIngredients).values({ recipeId: `r${k}`, ingredientId: k + 1, quantity: "100", unitId: 1, order: 0 }).run();
  }
}

/** A one-week plan from NOW (Sunday 2026-11-01), shopping on Monday (for Sun–Wed) and Thursday. */
function seedPlan() {
  return setupMealPlan(
    db,
    familyId,
    { iterationWeeks: 1, shoppingDays: [0, 3], servings: 2, knownRatio: 1, defaultLeftoverDays: 0, excludedTagIds: [] },
    NOW,
    mulberry32(3),
  ).iterationId;
}

const entriesOf = (iterationId: string) =>
  db.select().from(mealPlanEntries).where(eq(mealPlanEntries.iterationId, iterationId)).all().sort((a, b) => a.date.localeCompare(b.date));

/** What the plan needs, per shopping day (computed live; no list is stored). */
function itemsOf() {
  return shoppingNeeds(db, familyId, { from: "2000-01-01", locale: "en" }).flatMap((d) =>
    d.items.map((i) => ({ date: d.date, ingredientId: i.ingredientId, quantity: i.quantity })),
  );
}

beforeEach(() => {
  db = createTestDb();
  const owner = makeUser(db);
  familyId = makeFamily(db, owner.id).id;
  const v = makeUser(db);
  db.insert(familyMembers).values({ familyId, userId: v.id, role: "viewer", joinedAt: NOW }).run();
  call = caller(token(owner.id));
  viewer = caller(token(v.id));
  stranger = caller(token(makeUser(db).id));
  seedRecipes();
});

describe("GET /meals/plan", () => {
  it("answers without a plan, with the tags for the setup form", async () => {
    const res = await viewer("GET", "/meals/plan");
    expect(res.status).toBe(200);
    expect(res.data.plan).toBeNull();
    expect(res.data.away).toEqual({});
    expect(res.data.tags.length).toBeGreaterThan(0);
    expect(res.data.tags[0]).toEqual(expect.objectContaining({ id: expect.any(String), category: expect.any(String), nameEn: expect.any(String), nameDe: expect.any(String) }));
    expect((await stranger("GET", "/meals/plan")).status).toBe(404);
  });

  it("returns the plan with its iterations, meals, shopping days and away days", async () => {
    const iterationId = seedPlan();
    db.update(calEntryTypes).set({ away: true }).where(and(eq(calEntryTypes.familyId, familyId), eq(calEntryTypes.id, "vacation"))).run();
    db.insert(calEntries).values({ familyId, day: "2026-11-05", year: 2026, typeId: "vacation" }).run();
    const res = await viewer("GET", "/meals/plan");
    expect(res.status).toBe(200);
    const { plan, away } = res.data;
    expect(plan).toEqual(expect.objectContaining({ iterationWeeks: 1, shoppingDays: [0, 3], servings: 2, knownRatio: "1", defaultLeftoverDays: 0, excludedTagIds: [] }));
    expect(plan.iterations).toHaveLength(1);
    const it0 = plan.iterations[0];
    expect(it0).toEqual(expect.objectContaining({ id: iterationId, startDate: "2026-11-01", endDate: "2026-11-07", status: "ACTIVE" }));
    expect(it0.entries[0]).toEqual(
      expect.objectContaining({ id: expect.any(String), date: "2026-11-01", mealType: "LUNCH", recipeId: expect.any(String), recipeTitle: expect.stringMatching(/^Recipe /), servings: 2, isLeftover: false, sourceEntryId: null, isLocked: false }),
    );
    expect(it0.shoppingDates).toEqual(["2026-11-02", "2026-11-05"]);
    expect(it0).not.toHaveProperty("shoppingLists");
    expect(away).toEqual({ "2026-11-05": ["Vacation"] });
  });
});

describe("changing the plan", () => {
  const setup = { iterationWeeks: 2, shoppingDays: [5], servings: 3, knownRatio: 0.5, defaultLeftoverDays: 1, excludedTagIds: [] };

  it("sets the plan up (editors only, shopping days checked)", async () => {
    expect((await viewer("POST", "/meals/plan/setup", setup)).status).toBe(403);
    const bad = await call("POST", "/meals/plan/setup", { ...setup, shoppingDays: [0, 1] });
    expect(bad.status).toBe(422);
    const res = await call("POST", "/meals/plan/setup", setup);
    expect(res.status).toBe(200);
    expect(res.data.iterationId).toEqual(expect.any(String));
    const { plan } = (await call("GET", "/meals/plan")).data;
    expect(plan).toEqual(expect.objectContaining({ iterationWeeks: 2, shoppingDays: [5], servings: 3, knownRatio: "0.5" }));
    expect(plan.iterations[0].endDate).toBe("2026-11-14");
  });

  it("renews an iteration and can be undone through /meals/plan/restore", async () => {
    const iterationId = seedPlan();
    const before = entriesOf(iterationId).map((e) => [e.date, e.recipeId]);
    expect((await viewer("POST", `/meals/plan/iterations/${iterationId}/renew`)).status).toBe(403);
    const res = await call("POST", `/meals/plan/iterations/${iterationId}/renew`);
    expect(res.status).toBe(200);
    expect(res.data.iterationId).toBe(iterationId);
    expect(res.data.undo.restore[0].id).toBe(iterationId);
    expect((await call("POST", "/meals/plan/restore", res.data.undo)).status).toBe(200);
    expect(entriesOf(iterationId).map((e) => [e.date, e.recipeId])).toEqual(before);
    expect((await call("POST", "/meals/plan/iterations/nope/renew")).status).toBe(404);
  });

  it("starts the next iteration, archiving the last one; undo removes it", async () => {
    const first = seedPlan();
    const res = await call("POST", "/meals/plan/next");
    expect(res.status).toBe(200);
    const next = db.select().from(planIterations).where(eq(planIterations.id, res.data.iterationId)).get()!;
    expect(next.startDate).toBe("2026-11-08");
    expect(db.select().from(planIterations).where(eq(planIterations.id, first)).get()!.status).toBe("ARCHIVED");
    expect(res.data.undo.remove).toEqual([res.data.iterationId]);
    await call("POST", "/meals/plan/restore", res.data.undo);
    expect(db.select().from(planIterations).all().map((i) => [i.id, i.status])).toEqual([[first, "ACTIVE"]]);
    expect((await viewer("POST", "/meals/plan/next")).status).toBe(403);
  });

  it("swaps a meal; what the plan needs follows", async () => {
    const iterationId = seedPlan();
    const entries = entriesOf(iterationId);
    const used = new Set(entries.map((e) => e.recipeId));
    const unused = [...Array(14).keys()].map((k) => `r${k}`).find((id) => !used.has(id))!;
    // The meal of Monday (bought on Monday) is swapped.
    const monday = entries.find((e) => e.date === "2026-11-02")!;
    const tuesday = entries.find((e) => e.date === "2026-11-03")!;
    const ingOf = (recipeId: string) => Number(recipeId.slice(1)) + 1;

    expect((await viewer("PATCH", `/meals/plan/entries/${monday.id}`, { recipeId: unused })).status).toBe(403);
    expect((await call("PATCH", `/meals/plan/entries/${monday.id}`, { recipeId: "nope" })).status).toBe(404);
    const res = await call("PATCH", `/meals/plan/entries/${monday.id}`, { recipeId: unused });
    expect(res.status).toBe(200);
    expect(res.data.iterationId).toBe(iterationId);
    expect(entriesOf(iterationId).find((e) => e.id === monday.id)!.recipeId).toBe(unused);

    const items = itemsOf().filter((i) => i.date === "2026-11-02");
    const by = (ing: number) => items.find((i) => i.ingredientId === ing);
    expect(by(ingOf(monday.recipeId))).toBeUndefined();
    expect(by(ingOf(unused))).toEqual(expect.objectContaining({ quantity: "100" }));
    expect(by(ingOf(tuesday.recipeId))).toEqual(expect.objectContaining({ quantity: "100" }));

    // Undo puts the old meal back.
    await call("POST", "/meals/plan/restore", res.data.undo);
    expect(entriesOf(iterationId).find((e) => e.id === monday.id)!.recipeId).toBe(monday.recipeId);
    expect(itemsOf().some((i) => i.ingredientId === ingOf(unused))).toBe(false);
  });

  it("swaps and removes a meal together with its leftover days", async () => {
    const iterationId = seedPlan();
    const [cook, leftover] = entriesOf(iterationId).filter((e) => e.date === "2026-11-02" || e.date === "2026-11-03");
    db.update(mealPlanEntries).set({ recipeId: cook.recipeId, isLeftover: true, sourceEntryId: cook.id }).where(eq(mealPlanEntries.id, leftover.id)).run();
    const used = new Set(entriesOf(iterationId).map((e) => e.recipeId));
    const unused = [...Array(14).keys()].map((k) => `r${k}`).find((id) => !used.has(id))!;

    await call("PATCH", `/meals/plan/entries/${cook.id}`, { recipeId: unused });
    let after = entriesOf(iterationId);
    expect(after.find((e) => e.id === leftover.id)).toEqual(expect.objectContaining({ recipeId: unused, isLeftover: true, sourceEntryId: cook.id }));

    const res = await call("DELETE", `/meals/plan/entries/${cook.id}`);
    expect(res.status).toBe(200);
    after = entriesOf(iterationId);
    expect(after.find((e) => e.id === cook.id || e.id === leftover.id)).toBeUndefined();
    expect(itemsOf().some((i) => i.ingredientId === Number(unused.slice(1)) + 1)).toBe(false);
    expect((await viewer("DELETE", `/meals/plan/entries/${after[0].id}`)).status).toBe(403);
    expect((await call("DELETE", `/meals/plan/entries/${cook.id}`)).status).toBe(404);
  });

  it("makes a leftover day a meal of its own when it is swapped", async () => {
    const iterationId = seedPlan();
    const [cook, leftover] = entriesOf(iterationId).filter((e) => e.date === "2026-11-02" || e.date === "2026-11-03");
    db.update(mealPlanEntries).set({ recipeId: cook.recipeId, isLeftover: true, sourceEntryId: cook.id }).where(eq(mealPlanEntries.id, leftover.id)).run();
    await call("PATCH", `/meals/plan/entries/${leftover.id}`, { recipeId: "r0" });
    const after = entriesOf(iterationId);
    expect(after.find((e) => e.id === leftover.id)).toEqual(expect.objectContaining({ recipeId: "r0", isLeftover: false, sourceEntryId: null }));
    expect(after.find((e) => e.id === cook.id)!.recipeId).toBe(cook.recipeId);
  });
});

describe("drag and drop in the plan", () => {
  const ingOf = (recipeId: string) => Number(recipeId.slice(1)) + 1;
  const unusedRecipe = (iterationId: string) => {
    const used = new Set(entriesOf(iterationId).map((e) => e.recipeId));
    return [...Array(14).keys()].map((k) => `r${k}`).find((id) => !used.has(id))!;
  };
  const onDay = (iterationId: string, date: string) => entriesOf(iterationId).find((e) => e.date === date);
  const clearDay = (iterationId: string, date: string) =>
    db.delete(mealPlanEntries).where(and(eq(mealPlanEntries.iterationId, iterationId), eq(mealPlanEntries.date, date))).run();
  const makeLeftover = (iterationId: string, cookDate: string, leftoverDate: string) => {
    const cook = onDay(iterationId, cookDate)!;
    const leftover = onDay(iterationId, leftoverDate)!;
    db.update(mealPlanEntries).set({ recipeId: cook.recipeId, isLeftover: true, sourceEntryId: cook.id }).where(eq(mealPlanEntries.id, leftover.id)).run();
    return { cook, leftover };
  };

  it("puts a recipe on a day without lunch; undo takes it away", async () => {
    const iterationId = seedPlan();
    clearDay(iterationId, "2026-11-06");
    const recipeId = unusedRecipe(iterationId);
    const path = `/meals/plan/iterations/${iterationId}/entries`;
    expect((await viewer("POST", path, { date: "2026-11-06", recipeId })).status).toBe(403);
    expect((await call("POST", path, { date: "2026-11-06", recipeId: "nope" })).status).toBe(404);
    expect((await call("POST", "/meals/plan/iterations/nope/entries", { date: "2026-11-06", recipeId })).status).toBe(404);
    expect((await call("POST", path, { date: "2026-11-08", recipeId })).status).toBe(422);
    expect((await call("POST", path, { date: "2026-11-05", recipeId })).status).toBe(409);
    expect((await call("POST", path, { date: "2026-11-6", recipeId })).status).toBe(400);

    const res = await call("POST", path, { date: "2026-11-06", recipeId });
    expect(res.status).toBe(200);
    expect(res.data.iterationId).toBe(iterationId);
    expect(res.data.undo).toEqual({ restore: [expect.objectContaining({ id: iterationId })], remove: [] });
    expect(onDay(iterationId, "2026-11-06")).toEqual(
      expect.objectContaining({ mealType: "LUNCH", recipeId, servings: 2, isLeftover: false, sourceEntryId: null, isLocked: false }),
    );
    expect(itemsOf().find((i) => i.ingredientId === ingOf(recipeId))).toEqual(expect.objectContaining({ date: "2026-11-05", quantity: "100" }));

    expect((await call("POST", "/meals/plan/restore", res.data.undo)).status).toBe(200);
    expect(onDay(iterationId, "2026-11-06")).toBeUndefined();
    expect(itemsOf().some((i) => i.ingredientId === ingOf(recipeId))).toBe(false);
  });

  it("moves a meal to an empty day, its ingredients to that day's list", async () => {
    const iterationId = seedPlan();
    clearDay(iterationId, "2026-11-06");
    const monday = onDay(iterationId, "2026-11-02")!;
    const res = await call("POST", `/meals/plan/entries/${monday.id}/move`, { date: "2026-11-06" });
    expect(res.status).toBe(200);
    expect(res.data.iterationId).toBe(iterationId);
    expect(onDay(iterationId, "2026-11-02")).toBeUndefined();
    expect(onDay(iterationId, "2026-11-06")!.id).toBe(monday.id);
    expect(itemsOf().filter((i) => i.ingredientId === ingOf(monday.recipeId)).map((i) => i.date)).toEqual(["2026-11-05"]);

    await call("POST", "/meals/plan/restore", res.data.undo);
    expect(onDay(iterationId, "2026-11-02")!.id).toBe(monday.id);
    expect(onDay(iterationId, "2026-11-06")).toBeUndefined();
  });

  it("swaps two days; checks the day, the meal and the role", async () => {
    const iterationId = seedPlan();
    const sunday = onDay(iterationId, "2026-11-01")!;
    const tuesday = onDay(iterationId, "2026-11-03")!;
    const path = `/meals/plan/entries/${sunday.id}/move`;
    expect((await viewer("POST", path, { date: "2026-11-03" })).status).toBe(403);
    expect((await stranger("POST", path, { date: "2026-11-03" })).status).toBe(404);
    expect((await call("POST", "/meals/plan/entries/nope/move", { date: "2026-11-03" })).status).toBe(404);
    expect((await call("POST", path, { date: "2026-10-31" })).status).toBe(422);
    expect((await call("POST", path, { date: "2026-11-01" })).data).toEqual({ iterationId, undo: null });

    const res = await call("POST", path, { date: "2026-11-03" });
    expect(res.status).toBe(200);
    expect(onDay(iterationId, "2026-11-03")!.id).toBe(sunday.id);
    expect(onDay(iterationId, "2026-11-01")!.id).toBe(tuesday.id);
    expect(entriesOf(iterationId)).toHaveLength(7);

    await call("POST", "/meals/plan/restore", res.data.undo);
    expect(onDay(iterationId, "2026-11-01")!.id).toBe(sunday.id);
    expect(onDay(iterationId, "2026-11-03")!.id).toBe(tuesday.id);
  });

  it("makes a leftover a meal of its own once it lies on or before its meal's day", async () => {
    const iterationId = seedPlan();
    let { cook, leftover } = makeLeftover(iterationId, "2026-11-02", "2026-11-03");
    // Earlier, but still before the leftover: it stays a leftover.
    await call("POST", `/meals/plan/entries/${cook.id}/move`, { date: "2026-11-01" });
    expect(entriesOf(iterationId).find((e) => e.id === leftover.id)).toEqual(expect.objectContaining({ isLeftover: true, sourceEntryId: cook.id }));
    // After the leftover: it stands on its own.
    await call("POST", `/meals/plan/entries/${cook.id}/move`, { date: "2026-11-04" });
    expect(entriesOf(iterationId).find((e) => e.id === leftover.id)).toEqual(
      expect.objectContaining({ date: "2026-11-03", recipeId: cook.recipeId, isLeftover: false, sourceEntryId: null }),
    );

    // Moving the leftover itself: after its meal it stays one, before it it stands alone.
    ({ cook, leftover } = makeLeftover(iterationId, "2026-11-05", "2026-11-06"));
    await call("POST", `/meals/plan/entries/${leftover.id}/move`, { date: "2026-11-07" });
    expect(entriesOf(iterationId).find((e) => e.id === leftover.id)).toEqual(
      expect.objectContaining({ date: "2026-11-07", isLeftover: true, sourceEntryId: cook.id }),
    );
    const res = await call("POST", `/meals/plan/entries/${leftover.id}/move`, { date: "2026-11-05" });
    const after = entriesOf(iterationId);
    expect(after.find((e) => e.id === leftover.id)).toEqual(expect.objectContaining({ date: "2026-11-05", isLeftover: false, sourceEntryId: null }));
    expect(after.find((e) => e.id === cook.id)!.date).toBe("2026-11-07");

    // Undo puts the leftover back.
    await call("POST", "/meals/plan/restore", res.data.undo);
    expect(entriesOf(iterationId).find((e) => e.id === leftover.id)).toEqual(
      expect.objectContaining({ date: "2026-11-07", isLeftover: true, sourceEntryId: cook.id }),
    );
  });
});

describe("GET /meals/shopping", () => {
  it("computes what the plan needs per shopping day, for viewers too", async () => {
    const iterationId = seedPlan();
    const entries = entriesOf(iterationId);
    const res = await viewer("GET", "/meals/shopping?from=2026-11-01");
    expect(res.status).toBe(200);
    expect(res.data.days.map((d: any) => d.date)).toEqual(["2026-11-02", "2026-11-05"]);
    // Monday covers Sunday to Wednesday, Thursday the rest of the week.
    const ingOf = (recipeId: string) => Number(recipeId.slice(1)) + 1;
    const want = (from: string, to: string) =>
      entries.filter((e) => e.date >= from && e.date <= to).map((e) => ingOf(e.recipeId)).sort((a, b) => a - b);
    const got = (i: number) => res.data.days[i].items.map((x: any) => x.ingredientId).sort((a: number, b: number) => a - b);
    expect(got(0)).toEqual(want("2026-11-01", "2026-11-04"));
    expect(got(1)).toEqual(want("2026-11-05", "2026-11-07"));
    const first = res.data.days[0].items[0];
    expect(first).toEqual({
      key: `${first.ingredientId}-1`,
      ingredientId: expect.any(Number),
      name: `Ing ${first.ingredientId - 1}`,
      category: "PRODUCE",
      quantity: "100",
      unit: "g",
    });
    // Sorted by name.
    const names = res.data.days[0].items.map((x: any) => x.name);
    expect(names).toEqual([...names].sort((a: string, b: string) => a.localeCompare(b, "en")));
    expect((await stranger("GET", "/meals/shopping")).status).toBe(404);
  });

  it("starts at `from` (default today), names in the asked language", async () => {
    seedPlan();
    expect((await viewer("GET", "/meals/shopping")).data.days.map((d: any) => d.date)).toEqual(["2026-11-02", "2026-11-05"]);
    expect((await viewer("GET", "/meals/shopping?from=2026-11-03")).data.days.map((d: any) => d.date)).toEqual(["2026-11-05"]);
    expect((await viewer("GET", "/meals/shopping?from=2026-11-06")).data.days).toEqual([]);
    expect((await viewer("GET", "/meals/shopping?from=2026-11-3")).status).toBe(400);
    const de = await viewer("GET", "/meals/shopping?lang=de");
    expect(de.data.days[0].items[0].name).toMatch(/^Zutat /);
  });

  it("sums the meals of a day, scaled to their servings, and leaves out leftovers and empty days", async () => {
    const iterationId = seedPlan();
    const entries = entriesOf(iterationId);
    const sunday = entries.find((e) => e.date === "2026-11-01")!;
    const monday = entries.find((e) => e.date === "2026-11-02")!;
    // Monday cooks Sunday's recipe for 4 (twice the recipe's servings); Tuesday is its leftover.
    db.update(mealPlanEntries).set({ recipeId: sunday.recipeId, servings: 4 }).where(eq(mealPlanEntries.id, monday.id)).run();
    const tuesday = entries.find((e) => e.date === "2026-11-03")!;
    db.update(mealPlanEntries).set({ recipeId: sunday.recipeId, isLeftover: true, sourceEntryId: monday.id }).where(eq(mealPlanEntries.id, tuesday.id)).run();
    const ing = Number(sunday.recipeId.slice(1)) + 1;
    const day = (await viewer("GET", "/meals/shopping")).data.days[0];
    expect(day.items.filter((i: any) => i.ingredientId === ing)).toEqual([expect.objectContaining({ key: `${ing}-1`, quantity: "300" })]);
    // A shopping day whose meals are all gone isn't listed.
    db.delete(mealPlanEntries).where(and(eq(mealPlanEntries.iterationId, iterationId), eq(mealPlanEntries.date, "2026-11-05"))).run();
    db.delete(mealPlanEntries).where(and(eq(mealPlanEntries.iterationId, iterationId), eq(mealPlanEntries.date, "2026-11-06"))).run();
    db.delete(mealPlanEntries).where(and(eq(mealPlanEntries.iterationId, iterationId), eq(mealPlanEntries.date, "2026-11-07"))).run();
    expect((await viewer("GET", "/meals/shopping")).data.days.map((d: any) => d.date)).toEqual(["2026-11-02"]);
  });

  it("covers every iteration ahead", async () => {
    seedPlan();
    await call("POST", "/meals/plan/next");
    const days = (await viewer("GET", "/meals/shopping")).data.days.map((d: any) => d.date);
    expect(days).toEqual(["2026-11-02", "2026-11-05", "2026-11-09", "2026-11-12"]);
  });

  it("answers without a plan; the old shopping routes are gone", async () => {
    expect((await viewer("GET", "/meals/shopping")).data).toEqual({ days: [] });
    seedPlan();
    for (const [method, path] of [
      ["GET", "/meals/shopping/lists/x"],
      ["GET", "/meals/shopping/units"],
      ["POST", "/meals/shopping/check"],
      ["PATCH", "/meals/shopping/items/x"],
      ["DELETE", "/meals/shopping/items/x"],
      ["POST", "/meals/shopping/items/x/move"],
    ]) {
      expect((await call(method, path, method === "GET" || method === "DELETE" ? undefined : {})).status, path).toBe(404);
    }
    expect((await call("DELETE", "/meals/plan")).data).toEqual({ ok: true });
  });
});
