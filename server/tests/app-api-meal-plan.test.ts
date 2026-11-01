// The native app's meal plan and shopping routes (lib/meals/app-routes-plan.ts) on the family
// API, signed in with API tokens: viewers read, editors change.

import { and, eq } from "drizzle-orm";
import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import {
  calEntries, calEntryTypes, familyMembers, ingredients, mealPlanEntries, mealPlans, planIterations, recipeIngredients,
  recipes, shoppingListItems, shoppingLists, units,
} from "@/lib/db/schema";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { applyTransactionOps } from "@/lib/finance/finance";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { handleMealPlanApp } from "@/lib/meals/app-routes-plan";
import { handleMeals } from "@/lib/meals/family-routes";
import { setupMealPlan } from "@/lib/meals/meal-plan/setup";
import { mulberry32 } from "@/lib/meals/domain/rng";
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

function itemsOf(iterationId: string) {
  return db
    .select({ id: shoppingListItems.id, date: shoppingLists.shoppingDate, ingredientId: shoppingListItems.ingredientId, quantity: shoppingListItems.quantity, isChecked: shoppingListItems.isChecked })
    .from(shoppingListItems)
    .innerJoin(shoppingLists, eq(shoppingLists.id, shoppingListItems.shoppingListId))
    .where(eq(shoppingLists.iterationId, iterationId))
    .all();
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

  it("returns the plan with its iterations, meals, lists and away days", async () => {
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
    expect(it0.shoppingLists.map((l: any) => l.shoppingDate).sort()).toEqual(["2026-11-02", "2026-11-05"]);
    expect(it0.shoppingLists[0].itemCount).toBeGreaterThan(0);
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

  it("swaps a meal, keeping ticks and what was added by hand", async () => {
    const iterationId = seedPlan();
    const entries = entriesOf(iterationId);
    const used = new Set(entries.map((e) => e.recipeId));
    const unused = [...Array(14).keys()].map((k) => `r${k}`).find((id) => !used.has(id))!;
    // The meal of Monday (bought on Monday) is swapped; Tuesday's ingredient is ticked and
    // got 50 g more by hand; a new item was added by hand.
    const monday = entries.find((e) => e.date === "2026-11-02")!;
    const tuesday = entries.find((e) => e.date === "2026-11-03")!;
    const ingOf = (recipeId: string) => Number(recipeId.slice(1)) + 1;
    const sunday = db.select().from(shoppingLists).where(and(eq(shoppingLists.iterationId, iterationId), eq(shoppingLists.shoppingDate, "2026-11-02"))).get()!;
    const tue = db.select().from(shoppingListItems).where(and(eq(shoppingListItems.shoppingListId, sunday.id), eq(shoppingListItems.ingredientId, ingOf(tuesday.recipeId)))).get()!;
    db.update(shoppingListItems).set({ isChecked: true, quantity: "150" }).where(eq(shoppingListItems.id, tue.id)).run();
    const added = await call("POST", `/meals/shopping/lists/${sunday.id}/items`, { name: "Milk", quantity: "2", unitId: 2, category: "DAIRY" });
    expect(added.status).toBe(200);
    expect(added.data).toEqual({ id: expect.any(String), merged: false, previousQuantity: null });

    expect((await viewer("PATCH", `/meals/plan/entries/${monday.id}`, { recipeId: unused })).status).toBe(403);
    expect((await call("PATCH", `/meals/plan/entries/${monday.id}`, { recipeId: "nope" })).status).toBe(404);
    const res = await call("PATCH", `/meals/plan/entries/${monday.id}`, { recipeId: unused });
    expect(res.status).toBe(200);
    expect(res.data.iterationId).toBe(iterationId);
    expect(entriesOf(iterationId).find((e) => e.id === monday.id)!.recipeId).toBe(unused);

    const items = itemsOf(iterationId).filter((i) => i.date === "2026-11-02");
    const by = (ing: number) => items.find((i) => i.ingredientId === ing);
    expect(by(ingOf(monday.recipeId))).toBeUndefined();
    expect(by(ingOf(unused))).toEqual(expect.objectContaining({ quantity: "100", isChecked: false }));
    expect(by(ingOf(tuesday.recipeId))).toEqual(expect.objectContaining({ quantity: "150", isChecked: true }));
    const milk = db.select().from(ingredients).where(eq(ingredients.nameEn, "Milk")).get()!;
    expect(milk.category).toBe("DAIRY");
    expect(by(milk.id)).toEqual(expect.objectContaining({ quantity: "2", isChecked: false }));

    // Undo puts the old meal and list back.
    await call("POST", "/meals/plan/restore", res.data.undo);
    expect(entriesOf(iterationId).find((e) => e.id === monday.id)!.recipeId).toBe(monday.recipeId);
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
    expect(itemsOf(iterationId).some((i) => i.ingredientId === Number(unused.slice(1)) + 1)).toBe(false);
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
    expect(itemsOf(iterationId).find((i) => i.ingredientId === ingOf(recipeId))).toEqual(expect.objectContaining({ date: "2026-11-05", quantity: "100" }));

    expect((await call("POST", "/meals/plan/restore", res.data.undo)).status).toBe(200);
    expect(onDay(iterationId, "2026-11-06")).toBeUndefined();
    expect(itemsOf(iterationId).some((i) => i.ingredientId === ingOf(recipeId))).toBe(false);
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
    expect(itemsOf(iterationId).filter((i) => i.ingredientId === ingOf(monday.recipeId)).map((i) => i.date)).toEqual(["2026-11-05"]);

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

describe("moving shopping items", () => {
  type Item = typeof shoppingListItems.$inferSelect;
  let a: string; // list of Monday 2026-11-02
  let b: string; // list of Thursday 2026-11-05
  const item = (id: string): Item | undefined => db.select().from(shoppingListItems).where(eq(shoppingListItems.id, id)).get();
  const itemsOn = (listId: string) => db.select().from(shoppingListItems).where(eq(shoppingListItems.shoppingListId, listId)).all();
  const move = (id: string, body: unknown) => call("POST", `/meals/shopping/items/${id}/move`, body);

  beforeEach(() => {
    const iterationId = seedPlan();
    const lists = db.select().from(shoppingLists).where(eq(shoppingLists.iterationId, iterationId)).all();
    a = lists.find((l) => l.shoppingDate === "2026-11-02")!.id;
    b = lists.find((l) => l.shoppingDate === "2026-11-05")!.id;
  });

  it("moves a whole item, and back", async () => {
    const x = itemsOn(a)[0];
    expect((await viewer("POST", `/meals/shopping/items/${x.id}/move`, { listId: b })).status).toBe(403);
    const res = await move(x.id, { listId: b });
    expect(res.status).toBe(200);
    expect(res.data).toEqual({ id: x.id, merged: false, previousQuantity: null, fromListId: a, quantity: "100" });
    expect(item(x.id)!.shoppingListId).toBe(b);
    const back = await move(x.id, { listId: a });
    expect(back.data).toEqual({ id: x.id, merged: false, previousQuantity: null, fromListId: b, quantity: "100" });
    expect(item(x.id)).toEqual(x);
  });

  it("merges into an open item of the same ingredient; undo moves the quantity back", async () => {
    const y = itemsOn(a)[0];
    const open = await call("POST", `/meals/shopping/lists/${b}/items`, { name: `Ing ${y.ingredientId - 1}`, quantity: "30", unitId: 1 });
    expect(open.data.merged).toBe(false);
    const res = await move(y.id, { listId: b });
    expect(res.data).toEqual({ id: open.data.id, merged: true, previousQuantity: "30", fromListId: a, quantity: "100" });
    expect(item(y.id)).toBeUndefined();
    expect(item(open.data.id)!.quantity).toBe("130");

    const undo = await move(res.data.id, { listId: res.data.fromListId, quantity: res.data.quantity });
    expect(undo.status).toBe(200);
    expect(undo.data).toEqual({ id: expect.any(String), merged: false, previousQuantity: null, fromListId: b, quantity: "100" });
    expect(item(open.data.id)!.quantity).toBe("30");
    expect(item(undo.data.id)).toEqual(expect.objectContaining({ shoppingListId: a, ingredientId: y.ingredientId, unitId: y.unitId, quantity: "100", isChecked: false }));
  });

  it("moves part of an item, leaving the rest; moving it back merges it again", async () => {
    const y = itemsOn(a)[0];
    expect((await move(y.id, { listId: b, quantity: "0" })).status).toBe(422);
    expect((await move(y.id, { listId: b, quantity: "100.5" })).status).toBe(422);
    expect((await move(y.id, { listId: b, quantity: "lots" })).status).toBe(422);
    const res = await move(y.id, { listId: b, quantity: "40,5" });
    expect(res.status).toBe(200);
    expect(res.data).toEqual({ id: expect.any(String), merged: false, previousQuantity: null, fromListId: a, quantity: "40.5" });
    expect(res.data.id).not.toBe(y.id);
    expect(item(y.id)!.quantity).toBe("59.5");
    expect(item(res.data.id)).toEqual(expect.objectContaining({ shoppingListId: b, ingredientId: y.ingredientId, quantity: "40.5", isChecked: false }));

    const back = await move(res.data.id, { listId: a });
    expect(back.data).toEqual({ id: y.id, merged: true, previousQuantity: "59.5", fromListId: b, quantity: "40.5" });
    expect(item(y.id)!.quantity).toBe("100");
    expect(item(res.data.id)).toBeUndefined();

    // All of it is the whole item.
    const all = await move(y.id, { listId: b, quantity: 100 });
    expect(all.data).toEqual({ id: y.id, merged: false, previousQuantity: null, fromListId: a, quantity: "100" });
  });

  it("keeps a ticked item's tick and doesn't merge it", async () => {
    const z = itemsOn(a)[0];
    db.update(shoppingListItems).set({ isChecked: true }).where(eq(shoppingListItems.id, z.id)).run();
    const open = await call("POST", `/meals/shopping/lists/${b}/items`, { name: `Ing ${z.ingredientId - 1}`, quantity: "30", unitId: 1 });
    const res = await move(z.id, { listId: b });
    expect(res.data).toEqual({ id: z.id, merged: false, previousQuantity: null, fromListId: a, quantity: "100" });
    expect(item(z.id)).toEqual(expect.objectContaining({ shoppingListId: b, isChecked: true, quantity: "100" }));
    expect(item(open.data.id)!.quantity).toBe("30");
    await move(z.id, { listId: a });
    expect(item(z.id)).toEqual(expect.objectContaining({ shoppingListId: a, isChecked: true, quantity: "100" }));
  });

  it("refuses the same list and what isn't the family's", async () => {
    const x = itemsOn(a)[0];
    expect((await move(x.id, { listId: a })).status).toBe(422);
    expect((await move("nope", { listId: b })).status).toBe(404);
    expect((await move(x.id, { listId: "nope" })).status).toBe(404);
    expect((await stranger("POST", `/meals/shopping/items/${x.id}/move`, { listId: b })).status).toBe(404);
    // Another family's list.
    const other = makeFamily(db, makeUser(db).id).id;
    db.insert(mealPlans).values({ id: "other-plan", familyId: other, createdAt: NOW }).run();
    db.insert(planIterations).values({ id: "other-it", mealPlanId: "other-plan", startDate: "2026-11-01", endDate: "2026-11-07", createdAt: NOW }).run();
    db.insert(shoppingLists).values({ id: "other-list", iterationId: "other-it", shoppingDate: "2026-11-02", createdAt: NOW }).run();
    expect((await move(x.id, { listId: "other-list" })).status).toBe(404);
    expect(item(x.id)).toEqual(x);
  });
});

describe("shopping", () => {
  it("lists the shopping lists with the latest one, names in the asked language", async () => {
    const iterationId = seedPlan();
    const empty = await viewer("GET", "/meals/shopping");
    expect(empty.status).toBe(200);
    expect(empty.data.lists.map((l: any) => l.shoppingDate)).toEqual(["2026-11-05", "2026-11-02"]);
    expect(empty.data.lists[0]).toEqual(
      expect.objectContaining({ id: expect.any(String), iterationId, iterationStatus: "ACTIVE", itemCount: expect.any(Number), checkedCount: 0 }),
    );
    const latest = empty.data.latest;
    expect(latest.items[0]).toEqual(
      expect.objectContaining({ id: expect.any(String), ingredientName: expect.stringMatching(/^Ing /), category: "PRODUCE", quantity: "100", unitAbbreviation: "g", isChecked: false }),
    );
    const de = await viewer("GET", `/meals/shopping/lists/${latest.id}?lang=de`);
    expect(de.status).toBe(200);
    expect(de.data.list.items[0].ingredientName).toMatch(/^Zutat /);
    expect((await viewer("GET", "/meals/shopping/lists/nope")).status).toBe(404);
    expect((await stranger("GET", `/meals/shopping/lists/${latest.id}`)).status).toBe(404);
  });

  it("answers without a plan", async () => {
    const res = await viewer("GET", "/meals/shopping");
    expect(res.data).toEqual({ lists: [], latest: null });
  });

  it("shows what the shopping trip cost", async () => {
    seedPlan();
    const store = new DrizzleFinanceStore(db);
    await applyTransactionOps(store, familyId, [{ action: "add", date: "2026-11-05", amountCents: -2350, categoryId: "groceries", payee: "Rewe" }]);
    const { lists } = (await viewer("GET", "/meals/shopping")).data;
    const res = await viewer("GET", `/meals/shopping/lists/${lists[0].id}/spent`);
    expect(res.status).toBe(200);
    expect(res.data).toEqual(
      expect.objectContaining({ currency: "EUR", from: "2026-11-04", to: "2026-11-06", totalCents: 2350, category: expect.objectContaining({ id: "groceries" }) }),
    );
    expect(res.data.transactions).toEqual([expect.objectContaining({ date: "2026-11-05", payee: "Rewe", amountCents: -2350 })]);
  });

  it("adds items (merging into an open one), and needs an editor", async () => {
    seedPlan();
    const { latest } = (await call("GET", "/meals/shopping")).data;
    const units = (await viewer("GET", "/meals/shopping/units")).data.units;
    expect(units).toEqual([
      { id: 1, abbreviation: "g", nameEn: "gram", nameDe: "Gramm" },
      { id: 2, abbreviation: "Stk", nameEn: "piece", nameDe: "Stück" },
    ]);
    const name = latest.items[0].ingredientName; // an existing ingredient, by its English name
    expect((await viewer("POST", `/meals/shopping/lists/${latest.id}/items`, { name, quantity: "1", unitId: 1 })).status).toBe(403);
    const res = await call("POST", `/meals/shopping/lists/${latest.id}/items`, { name: name.toLowerCase(), quantity: "50", unitId: 1 });
    expect(res.data).toEqual({ id: latest.items[0].id, merged: true, previousQuantity: "100" });
    const de = await call("POST", `/meals/shopping/lists/${latest.id}/items`, { name: "Zutat 13", quantity: 2.5, unitId: 2 });
    expect(de.data.merged).toBe(false);
    expect(db.select().from(shoppingListItems).where(eq(shoppingListItems.id, de.data.id)).get()).toEqual(
      expect.objectContaining({ ingredientId: 14, unitId: 2, quantity: "2.5" }),
    );
    const count = db.select().from(ingredients).all().length;
    expect((await call("POST", `/meals/shopping/lists/${latest.id}/items`, { name: "Brand new", quantity: "0", unitId: 1 })).status).toBe(422);
    expect((await call("POST", "/meals/shopping/lists/nope/items", { name: "Brand new", quantity: "1", unitId: 1 })).status).toBe(404);
    expect((await call("POST", `/meals/shopping/lists/${latest.id}/items`, { name: "Brand new", quantity: "1", unitId: 99 })).status).toBe(404);
    expect(db.select().from(ingredients).all().length).toBe(count);
  });

  it("leaves the existing meals routes alone", async () => {
    seedPlan();
    const { latest } = (await call("GET", "/meals/shopping")).data;
    const id = latest.items[0].id;
    expect((await call("POST", "/meals/shopping/check", { ids: [id], checked: true })).data).toEqual({ count: 1 });
    expect((await call("PATCH", `/meals/shopping/items/${id}`, { quantity: "3" })).data).toEqual({ id, quantity: "3" });
    expect((await call("DELETE", `/meals/shopping/items/${id}`)).data).toEqual({ deleted: id });
    expect((await call("GET", "/meals/shopping/nothing")).status).toBe(404);
    expect((await call("DELETE", "/meals/plan")).data).toEqual({ ok: true });
  });
});
