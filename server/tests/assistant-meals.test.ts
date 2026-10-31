// The assistant's meal tools (lib/assistant/tools/meals.ts) against the in-memory database:
// recipes, the meal plan ("next week without fish") and the shopping list, every change with
// undo steps that are replayed through the family API (lib/meals/family-routes.ts); viewers
// and families with changes off get only the tools that read. One chat runs through the
// worker with the mock AI.

import { and, eq } from "drizzle-orm";
import { afterEach, describe, expect, it } from "vitest";
import type { NetOptions } from "@/lib/assistant/net";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { runTool, type ToolContext, TOOLS, toolsFor } from "@/lib/assistant/tools";
import {
  calEntries, calEntryTypes, mealPlanEntries, planIterations, recipeTags, recipes, shoppingListItems,
} from "@/lib/db/schema";
import { getRecipe, listTags } from "@/lib/meals/queries/recipes";
import { getLatestShoppingList } from "@/lib/meals/queries/shopping";
import { seed } from "@/lib/meals/seed";
import { type AssistantTest, assistantTest, configure, type Event, net } from "@/lib/test/assistant";

let current: AssistantTest[] = [];
afterEach(async () => {
  await Promise.all(current.map((t) => t.stop()));
  current = [];
});

const TODAY = "2026-11-02"; // a Monday

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Res = { ok: boolean; result: any; summary: string; change?: any };

function family(worker = false) {
  const t = assistantTest({ worker });
  current.push(t);
  seed(t.db);
  const ctx = (userId = t.editor.id): ToolContext => ({
    lang: "en",
    calendar: new DrizzleCalendarStore(t.db),
    finance: new DrizzleFinanceStore(t.db),
    db: t.db,
    familyId: t.familyId,
    net: {} as NetOptions,
    search: null,
    userId,
    today: TODAY,
    now: () => new Date(`${TODAY}T09:00:00Z`),
  });
  const tool = async (name: string, args: unknown, c = ctx()): Promise<Res> =>
    (await runTool(name, JSON.stringify(args), c, new Set(Object.keys(TOOLS)))) as Res;
  /** Replays a change's undo steps like the app does. */
  const undo = async (change: { undo: { method: string; path: string; body?: unknown }[] }, call = t.call) => {
    for (const step of change.undo) {
      const res = await call(step.method, t.f + step.path, step.body);
      expect(res.status, JSON.stringify(res.data)).toBeLessThan(300);
    }
  };
  const tag = (name: string) => listTags(t.db, t.familyId).find((x) => x.nameEn === name)!;
  return { t, ctx, tool, undo, tag };
}

/** Eight recipes, two of them with fish. */
async function withRecipes(f: ReturnType<typeof family>) {
  const ids: string[] = [];
  for (let i = 1; i <= 8; i++) {
    const fish = i <= 2;
    const res = await f.tool("save_recipe", {
      title: fish ? `Fish dish ${i}` : `Veggie dish ${i}`,
      list: "KNOWN",
      leftoverDays: 0,
      tags: fish ? ["Fish"] : ["Vegetarian"],
      ingredients: [
        { name: fish ? "Salmon" : "Tomato", quantity: 200, unit: "g" },
        { name: "Zwiebel", quantity: 1, unit: "piece" },
      ],
      steps: ["Cook."],
    });
    expect(res.ok, JSON.stringify(res.result)).toBe(true);
    ids.push(res.result.id);
  }
  return ids;
}

describe("recipe tools", () => {
  it("add a recipe (new ingredients too) and undo deletes it", async () => {
    const f = family();
    const res = await f.tool("save_recipe", {
      title: "Shakshuka",
      servings: 3,
      prepMinutes: 10,
      cookMinutes: 20,
      tags: ["vegetarisch", "Egg"],
      ingredients: [
        { name: "Tomato", quantity: "400", unit: "g" },
        { name: "Ei", quantity: 4, unit: "Stk" },
        { name: "Sumach", nameDe: "Sumach", quantity: 1, unit: "tsp", category: "pantry" },
      ],
      steps: ["Simmer the tomatoes.", "Add the eggs."],
    });
    expect(res.ok, JSON.stringify(res.result)).toBe(true);
    expect(res.change.summary).toBe("Added the recipe “Shakshuka”");
    const r = getRecipe(f.t.db, f.t.familyId, res.result.id)!;
    expect(r.listType).toBe("TO_TRY");
    expect(r.tags.map((x) => x.nameEn).sort()).toEqual(["Egg", "Vegetarian"]);
    expect(r.ingredients).toHaveLength(3);
    expect(r.manualSteps.map((s) => s.instruction)).toEqual(["Simmer the tomatoes.", "Add the eggs."]);

    const read = await f.tool("get_recipe", { recipe: "shakshuka" });
    expect(read.result.ingredients).toEqual([
      { name: "tomato", quantity: "400", unit: "g" },
      { name: "egg", quantity: "4", unit: "Stk" },
      { name: "Sumach", quantity: "1", unit: "TL" },
    ]);

    await f.undo(res.change);
    expect(getRecipe(f.t.db, f.t.familyId, res.result.id)).toBeNull();
  });

  it("change a recipe in part, and undo puts it back as it was", async () => {
    const f = family();
    const [id] = await withRecipes(f);
    const before = getRecipe(f.t.db, f.t.familyId, id)!;
    const res = await f.tool("save_recipe", { recipe: "Fish dish 1", title: "Salmon bowl", list: "TO_TRY", ingredients: [{ name: "Rice", quantity: 150, unit: "g" }] });
    expect(res.ok, JSON.stringify(res.result)).toBe(true);
    const after = getRecipe(f.t.db, f.t.familyId, id)!;
    expect([after.title, after.listType, after.ingredients.length, after.manualSteps.length]).toEqual(["Salmon bowl", "TO_TRY", 1, 1]);
    expect(after.tags.map((x) => x.nameEn)).toEqual(["Fish"]);
    await f.undo(res.change);
    const back = getRecipe(f.t.db, f.t.familyId, id)!;
    expect([back.title, back.listType]).toEqual([before.title, before.listType]);
    expect(back.ingredients.map((i) => [i.ingredientId, i.quantity, i.unitId])).toEqual(
      before.ingredients.map((i) => [i.ingredientId, i.quantity, i.unitId]),
    );
  });

  it("list and search recipes by title, tag, list and ingredient", async () => {
    const f = family();
    await withRecipes(f);
    expect((await f.tool("list_recipes", {})).result.total).toBe(8);
    expect((await f.tool("list_recipes", { tags: ["fish"] })).result.recipes.map((r: { title: string }) => r.title)).toEqual([
      "Fish dish 1",
      "Fish dish 2",
    ]);
    expect((await f.tool("list_recipes", { ingredient: "lachs" })).result.total).toBe(0);
    expect((await f.tool("list_recipes", { ingredient: "salm" })).result.total).toBe(2);
    expect((await f.tool("list_recipes", { query: "veggie 7" })).result.recipes[0].title).toBe("Veggie dish 7");
    const withIng = await f.tool("list_recipes", { query: "Fish dish 1", withIngredients: true });
    expect(withIng.result.recipes[0].ingredients).toEqual(["Salmon", "onion"]);
    expect((await f.tool("list_recipes", { list: "TO_TRY" })).result.total).toBe(0);
    const bad = await f.tool("list_recipes", { tags: ["Pizza"] });
    expect(bad.ok).toBe(false);
    expect(bad.result.error).toMatch(/Unknown tag "Pizza"\. The tags are: .*Fish/);
  });

  it("explain what's wrong with a recipe the model sends", async () => {
    const f = family();
    const unit = await f.tool("save_recipe", { title: "X", ingredients: [{ name: "Tomato", quantity: 1, unit: "bucket" }] });
    expect(unit.result.error).toMatch(/Unknown unit "bucket"/);
    const qty = await f.tool("save_recipe", { title: "X", ingredients: [{ name: "Tomato", quantity: "lots", unit: "g" }] });
    expect(qty.result.error).toMatch(/quantity must be a number/);
    expect((await f.tool("save_recipe", { ingredients: [] })).result.error).toBe("title is required");
    expect((await f.tool("get_recipe", { recipe: "nothing like it" })).result.error).toMatch(/No recipe/);
  });
});

describe("meal plan tools", () => {
  it("set up a plan, read it, plan next week without fish, and undo that", async () => {
    const f = family();
    await withRecipes(f);
    const none = await f.tool("get_meal_plan", {});
    expect(none.result.plan).toBeNull();
    expect((await f.tool("plan_meals", { action: "next" })).result.error).toMatch(/no meal plan yet/);

    const setup = await f.tool("plan_meals", { action: "setup", weeks: 1, shoppingDays: ["Saturday"], servings: 3 });
    expect(setup.ok, JSON.stringify(setup.result)).toBe(true);
    expect([setup.result.from, setup.result.to, setup.result.meals.length]).toEqual([TODAY, "2026-11-08", 7]);
    expect((await f.tool("plan_meals", { action: "setup" })).result.error).toMatch(/has a meal plan already/);

    const read = await f.tool("get_meal_plan", {});
    expect(read.result.settings).toMatchObject({ iterationWeeks: 1, shoppingDays: ["Saturday"], servings: 3 });
    expect(read.result.meals[0]).toMatchObject({ date: TODAY, weekday: "Monday" });
    const firstId = read.result.iterations[0].id;
    const before = f.t.db.select().from(mealPlanEntries).where(eq(mealPlanEntries.iterationId, firstId)).all();

    const next = await f.tool("plan_meals", { action: "next", excludeTags: ["Fisch"] });
    expect(next.ok, JSON.stringify(next.result)).toBe(true);
    expect([next.result.from, next.result.to]).toEqual(["2026-11-09", "2026-11-15"]);
    expect(next.result.meals).toHaveLength(7);
    expect(next.result.meals.some((m: { recipe: string }) => m.recipe.startsWith("Fish"))).toBe(false);
    expect(next.change.summary).toBe("Planned the meals 2026-11-09 – 2026-11-15");
    // Only for this planning: the plan's own settings stay.
    expect((await f.tool("get_meal_plan", {})).result.settings.excludedTags).toEqual([]);
    expect(f.t.db.select().from(planIterations).where(eq(planIterations.id, firstId)).get()!.status).toBe("ARCHIVED");

    await f.undo(next.change);
    const its = f.t.db.select().from(planIterations).all();
    expect(its.map((i) => [i.id, i.status])).toEqual([[firstId, "ACTIVE"]]);
    const after = f.t.db.select().from(mealPlanEntries).where(eq(mealPlanEntries.iterationId, firstId)).all();
    expect(after.map((e) => [e.date, e.recipeId]).sort()).toEqual(before.map((e) => [e.date, e.recipeId]).sort());

    // Undo of the setup deletes the plan.
    await f.undo(setup.change);
    expect((await f.tool("get_meal_plan", {})).result.plan).toBeNull();
  });

  it("plan an iteration again; undo brings its meals and ticks back", async () => {
    const f = family();
    await withRecipes(f);
    await f.tool("plan_meals", { action: "setup", shoppingDays: ["Monday"] });
    const list = getLatestShoppingList(f.t.db, f.t.familyId, "en")!;
    const ticked = list.items[0];
    expect((await f.tool("tick_shopping_items", { items: [ticked.ingredientName], checked: true })).ok).toBe(true);
    const it = f.t.db.select().from(planIterations).get()!;
    const before = f.t.db.select().from(mealPlanEntries).where(eq(mealPlanEntries.iterationId, it.id)).all();

    const again = await f.tool("plan_meals", { action: "again", excludeTags: ["Vegetarian"] });
    expect(again.ok, JSON.stringify(again.result)).toBe(true);
    // Only the fish dishes are left (plus the gap-fill, which leaves out the excluded tags too).
    expect(again.result.meals.every((m: { recipe: string }) => m.recipe.startsWith("Fish"))).toBe(true);
    expect(getLatestShoppingList(f.t.db, f.t.familyId, "en")!.items.every((i) => !i.isChecked)).toBe(true);

    await f.undo(again.change);
    const back = f.t.db.select().from(mealPlanEntries).where(eq(mealPlanEntries.iterationId, it.id)).all();
    expect(back.map((e) => [e.id, e.recipeId, e.sourceEntryId])).toEqual(before.map((e) => [e.id, e.recipeId, e.sourceEntryId]));
    const restored = getLatestShoppingList(f.t.db, f.t.familyId, "en")!;
    expect(restored.items.find((i) => i.id === ticked.id)?.isChecked).toBe(true);
  });

  it("leave away days out and show them", async () => {
    const f = family();
    await withRecipes(f);
    f.t.db.insert(calEntryTypes).values({ familyId: f.t.familyId, year: 2026, id: "trip", name: "Trip", color: "#000000", role: "none", position: 9, away: true }).run();
    f.t.db.insert(calEntries).values({ familyId: f.t.familyId, year: 2026, day: "2026-11-04", typeId: "trip" }).run();
    const setup = await f.tool("plan_meals", { action: "setup", shoppingDays: ["Saturday"] });
    expect(setup.result.meals.map((m: { date: string }) => m.date)).not.toContain("2026-11-04");
    expect(setup.result.away).toEqual([{ date: "2026-11-04", types: ["Trip"] }]);
  });

  it("refuse other families' iterations in the restore route", async () => {
    const f = family();
    await withRecipes(f);
    const other = family();
    const res = await other.t.call("POST", `${other.t.f}/meals/plan/restore`, { restore: [], remove: ["nope"] });
    expect(res.status).toBe(404);
    // A viewer can't call it.
    expect((await f.t.view("POST", `${f.t.f}/meals/plan/restore`, { restore: [], remove: [] })).status).toBe(403);
  });
});

describe("shopping list tools", () => {
  it("read, tick and untick items (by name), and undo", async () => {
    const f = family();
    await withRecipes(f);
    expect((await f.tool("get_shopping_list", {})).result.error).toMatch(/no shopping list yet/);
    await f.tool("plan_meals", { action: "setup", shoppingDays: ["Monday"] });
    const read = await f.tool("get_shopping_list", {});
    expect(read.result.items.length).toBeGreaterThan(0);
    const onion = read.result.items.find((i: { name: string }) => i.name === "onion");
    const res = await f.tool("tick_shopping_items", { items: ["onion"], checked: true });
    expect(res.result.changed).toBe(1);
    expect(res.change.summary).toBe("1 item ticked off");
    expect(f.t.db.select().from(shoppingListItems).where(eq(shoppingListItems.id, onion.id)).get()!.isChecked).toBe(true);
    // Again: nothing changes, nothing to undo.
    expect((await f.tool("tick_shopping_items", { items: [onion.id], checked: true })).change).toBeUndefined();
    await f.undo(res.change);
    expect(f.t.db.select().from(shoppingListItems).where(eq(shoppingListItems.id, onion.id)).get()!.isChecked).toBe(false);
    expect((await f.tool("tick_shopping_items", { items: ["Caviar"], checked: true })).result.error).toBe("Not on the list: Caviar");
  });

  it("add items, merging with an open one of the same unit; undo takes them back", async () => {
    const f = family();
    await withRecipes(f);
    await f.tool("plan_meals", { action: "setup", shoppingDays: ["Monday"] });
    const before = getLatestShoppingList(f.t.db, f.t.familyId, "en")!;
    const onion = before.items.find((i) => i.ingredientName === "onion")!;
    const res = await f.tool("add_shopping_items", {
      items: [
        { name: "Milk", nameDe: "Milch", quantity: 1, unit: "l" },
        { name: "Onion", quantity: 2, unit: "Stk" },
      ],
    });
    expect(res.ok, JSON.stringify(res.result)).toBe(true);
    expect(res.change.summary).toBe("2 items added to the shopping list");
    const after = getLatestShoppingList(f.t.db, f.t.familyId, "en")!;
    expect(after.items).toHaveLength(before.items.length + 1);
    expect(after.items.find((i) => i.id === onion.id)!.quantity).toBe(String(Number(onion.quantity) + 2));
    await f.undo(res.change);
    const back = getLatestShoppingList(f.t.db, f.t.familyId, "en")!;
    expect(back.items.map((i) => [i.id, i.quantity])).toEqual(before.items.map((i) => [i.id, i.quantity]));
  });
});

describe("permissions", () => {
  it("viewers and families with changes off get only the reading meal tools", () => {
    const names = toolsFor({ writes: false, search: false }).map((t) => t.function.name);
    for (const n of ["list_recipes", "get_recipe", "get_meal_plan", "get_shopping_list"]) expect(names).toContain(n);
    for (const n of ["save_recipe", "plan_meals", "tick_shopping_items", "add_shopping_items"]) expect(names).not.toContain(n);
  });

  it("the undo routes are for editors of the family only", async () => {
    const f = family();
    const [id] = await withRecipes(f);
    expect((await f.t.view("DELETE", `${f.t.f}/meals/recipes/${id}`)).status).toBe(403);
    expect((await f.t.view("POST", `${f.t.f}/meals/shopping/check`, { ids: ["x"], checked: true })).status).toBe(403);
    const other = family();
    expect((await other.t.call("DELETE", `${other.t.f}/meals/recipes/${id}`)).status).toBe(404);
    expect(f.t.db.select().from(recipes).where(eq(recipes.id, id)).get()).toBeDefined();
  });

  it("a viewer's chat has no meal tools that change, and says so", async () => {
    const f = family(true);
    await configure(f.t);
    const res = await f.t.view("POST", `${f.t.ai}/chats`, { text: "add recipe Pancakes", today: TODAY, year: 2026, lang: "en", page: "meals" });
    expect(res.status).toBe(200);
    const sent = (net.aiBody.tools ?? []).map((t: { function: { name: string } }) => t.function.name);
    expect(sent).toContain("list_recipes");
    expect(sent).not.toContain("save_recipe");
    expect(net.aiBody.messages[0].content).toContain("You can only read: the user can only view this family");
    expect(f.t.db.select().from(recipes).all()).toHaveLength(0);
  });
});

describe("in a chat", () => {
  it("plans next week without fish through the worker, with an undo the app can replay", async () => {
    const f = family(true);
    await withRecipes(f);
    await f.tool("plan_meals", { action: "setup", shoppingDays: ["Saturday"] });
    await configure(f.t);
    const res = await f.t.call("POST", `${f.t.ai}/chats`, {
      text: "plan next week without Fish",
      today: TODAY,
      year: 2026,
      lang: "en",
      page: "meals",
    });
    expect(res.status).toBe(200);
    const ev = res.data as Event[];
    const items = ev.filter((e) => e.event === "items").flatMap((e) => e.data.items.map((i: { item: unknown }) => i.item));
    const change = items.find((i: { kind: string }) => i.kind === "change");
    expect(change).toMatchObject({ change: "plan", summary: "Planned the meals 2026-11-09 – 2026-11-15" });
    expect(items.at(-1)).toMatchObject({ kind: "assistant", text: expect.stringMatching(/^Planned 7 meals from 2026-11-09/) });
    // The instructions know the meals now.
    expect(net.aiBody.messages[0].content).toMatch(/Tags: .*Fish/);
    expect(net.aiBody.messages[0].content).not.toMatch(/no tools for them yet/);
    const latest = f.t.db.select().from(planIterations).all();
    expect(latest).toHaveLength(2);
    const fishIds = f.t.db
      .select({ id: recipeTags.recipeId })
      .from(recipeTags)
      .where(eq(recipeTags.tagId, f.tag("Fish").id))
      .all()
      .map((r) => r.id);
    const newest = latest.find((i) => i.startDate === "2026-11-09")!;
    const meals = f.t.db.select().from(mealPlanEntries).where(and(eq(mealPlanEntries.iterationId, newest.id))).all();
    expect(meals.some((m) => fishIds.includes(m.recipeId))).toBe(false);
    await f.undo(change);
    expect(f.t.db.select().from(planIterations).all()).toHaveLength(1);
  });
});
