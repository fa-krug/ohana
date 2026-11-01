// Routes of the family API for the native app (apple/): /meals/plan/... and /meals/shopping/...
// reads and changes the meal plan and shopping pages do with server actions.
// Registered before the meals' other routes; null for paths that aren't its own (handleMeals
// keeps POST /meals/shopping/check, PATCH|DELETE /meals/shopping/items/{id},
// POST /meals/plan/restore and DELETE /meals/plan).
//
//   GET    /meals/plan                          {plan: MealPlanView | null, away: {day: [type names]}, tags}
//   POST   /meals/plan/setup                    SetupPlanInput → {iterationId}            (the plan page's form)
//   POST   /meals/plan/next                     → {iterationId, undo}                      ("Start next iteration")
//   POST   /meals/plan/iterations/{id}/renew    → {iterationId, undo}                      ("Refresh")
//   POST   /meals/plan/iterations/{id}/entries  {date, recipeId} → {iterationId, undo}     (a recipe on a day without lunch; 409 if it has one)
//   PATCH  /meals/plan/entries/{id}             {recipeId} → {iterationId, undo}           (swap a meal)
//   DELETE /meals/plan/entries/{id}             → {iterationId, undo}                      (remove a meal)
//   POST   /meals/plan/entries/{id}/move        {date} → {iterationId, undo | null}        (to another day; that day's lunch takes its day)
//   GET    /meals/shopping?lang=                {lists: [summary], latest: ShoppingListView | null}
//   GET    /meals/shopping/lists/{id}?lang=     {list: ShoppingListView}
//   GET    /meals/shopping/lists/{id}/spent     ShoppingSpend (groceries spend of its shopping day ± 1)
//   POST   /meals/shopping/lists/{id}/items     {name, quantity, unitId, category?} → {id, merged, previousQuantity}
//   POST   /meals/shopping/items/{id}/move      {listId, quantity?} → {id, merged, previousQuantity, fromListId, quantity}
//   GET    /meals/shopping/units                {units: [{id, abbreviation, nameEn, nameDe}]}
//
// `undo` is the body for POST /meals/plan/restore that puts the plan back as it was.
// Viewers read; changes need an editor. Adding, swapping, moving or removing a meal makes the
// iteration's shopping lists new from its meals, keeping ticks and what was added by hand.

import { randomUUID } from "node:crypto";
import { and, asc, desc, eq, inArray, sql } from "drizzle-orm";
import { z } from "zod";
import type { Db } from "@/lib/db";
import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, readBody } from "@/lib/api/http";
import { AuthError } from "@/lib/auth/errors";
import {
  ingredients, mealPlanEntries, mealPlans, planIterations, recipes, shoppingListItems, shoppingLists, units,
} from "@/lib/db/schema";
import { shoppingSpend } from "@/lib/finance/groceries";
import { Decimal, quantize2 } from "./domain/decimal";
import { awayDays } from "./meal-plan/away";
import { generateNextIteration, renewIteration } from "./meal-plan/iterations";
import { setupMealPlan } from "./meal-plan/setup";
import { type IterationSnapshot, snapshotIteration } from "./meal-plan/snapshot";
import { getMealPlanView } from "./queries/meal-plan";
import { listTags } from "./queries/recipes";
import { getLatestShoppingList, getShoppingListById } from "./queries/shopping";
import { findOrCreateIngredient } from "./recipes/ingredients";
import { setupPlanSchema } from "./schemas/mutations";
import { generateShoppingListsForIteration } from "./shopping/generate";
import { addShoppingItem, moveShoppingItem } from "./shopping/items";

const CATEGORIES = ["PRODUCE", "DAIRY", "MEAT", "PANTRY", "FROZEN", "OTHER"] as const;

const swapSchema = z.object({ recipeId: z.string().min(1).max(64) });
const day = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, "The date must be YYYY-MM-DD")
  .refine((d) => !Number.isNaN(Date.parse(`${d}T00:00:00Z`)) && new Date(`${d}T00:00:00Z`).toISOString().startsWith(d), "Unknown date");
const addEntrySchema = z.object({ date: day, recipeId: z.string().min(1).max(64) });
const moveEntrySchema = z.object({ date: day });
const moveItemSchema = z.object({
  listId: z.string().min(1).max(64),
  quantity: z
    .union([z.string().max(40), z.number()])
    .transform((v) => String(v).trim().replace(",", "."))
    .optional(),
});
const addItemSchema = z.object({
  name: z.string().trim().min(1).max(80),
  quantity: z.union([z.string(), z.number()]).transform((v) => String(v).trim().replace(",", ".")),
  unitId: z.number().int(),
  category: z.enum(CATEGORIES).optional(),
});

export function handleMealPlanApp(ctx: Ctx): Promise<Response> | null {
  if (ctx.rest[0] !== "meals") return null;
  const [, area, sub, id, more, ...rest] = ctx.rest;
  if (rest.length) return null;
  const m = ctx.method;
  if (area === "plan") {
    if (m === "GET" && sub === undefined) return view(ctx, (familyId) => planResponse(ctx.db, familyId));
    if (m === "POST" && sub === "setup" && id === undefined) {
      return edit(ctx, async (familyId) => setupMealPlan(ctx.db, familyId, setupPlanSchema.parse(await readBody(ctx.req)), ctx.now));
    }
    if (m === "POST" && sub === "next" && id === undefined) return edit(ctx, async (familyId) => nextIteration(ctx, familyId));
    if (m === "POST" && sub === "iterations" && id !== undefined && more === "renew") {
      return edit(ctx, async (familyId) => {
        const before = snapshotIteration(ctx.db, familyId, id);
        renewIteration(ctx.db, familyId, id);
        return { iterationId: id, undo: { restore: [before], remove: [] } };
      });
    }
    if (m === "POST" && sub === "iterations" && id !== undefined && more === "entries") {
      return edit(ctx, async (familyId) => addEntry(ctx.db, familyId, id, addEntrySchema.parse(await readBody(ctx.req))));
    }
    if (m === "POST" && sub === "entries" && id !== undefined && more === "move") {
      return edit(ctx, async (familyId) => moveEntry(ctx.db, familyId, id, moveEntrySchema.parse(await readBody(ctx.req)).date));
    }
    if (sub === "entries" && id !== undefined && more === undefined) {
      if (m === "PATCH") {
        return edit(ctx, async (familyId) => {
          const { recipeId } = swapSchema.parse(await readBody(ctx.req));
          return changeEntry(ctx.db, familyId, id, { swap: recipeId });
        });
      }
      if (m === "DELETE") return edit(ctx, async (familyId) => changeEntry(ctx.db, familyId, id, { remove: true }));
    }
    return null;
  }
  if (area === "shopping") {
    if (m === "GET" && sub === undefined) return view(ctx, async (familyId) => shoppingOverview(ctx, familyId));
    if (m === "GET" && sub === "units" && id === undefined) {
      return view(ctx, async () => ({
        units: ctx.db
          .select({ id: units.id, abbreviation: units.abbreviation, nameEn: units.nameEn, nameDe: units.nameDe })
          .from(units)
          .orderBy(asc(units.id))
          .all(),
      }));
    }
    if (sub === "lists" && id !== undefined) {
      if (m === "GET" && more === undefined) {
        return view(ctx, async (familyId) => {
          const list = getShoppingListById(ctx.db, familyId, id, lang(ctx));
          if (!list) throw new HttpError(404, "Shopping list not found");
          return { list };
        });
      }
      if (m === "GET" && more === "spent") {
        return view(ctx, async (familyId) => {
          const list = getShoppingListById(ctx.db, familyId, id, "en");
          if (!list) throw new HttpError(404, "Shopping list not found");
          if (!list.shoppingDate) throw new HttpError(404, "The list has no shopping day");
          return shoppingSpend(ctx.db, familyId, list.shoppingDate);
        });
      }
      if (m === "POST" && more === "items") {
        return edit(ctx, async (familyId) => addItem(ctx.db, familyId, id, addItemSchema.parse(await readBody(ctx.req))));
      }
    }
    if (m === "POST" && sub === "items" && id !== undefined && more === "move") {
      return edit(ctx, async (familyId) => moveShoppingItem(ctx.db, familyId, id, moveItemSchema.parse(await readBody(ctx.req))));
    }
    return null;
  }
  return null;
}

async function view(ctx: Ctx, fn: (familyId: string) => unknown): Promise<Response> {
  const { family } = await ctx.load("view");
  return json(await fn(family.id));
}

async function edit(ctx: Ctx, fn: (familyId: string) => Promise<unknown>): Promise<Response> {
  const { family } = await ctx.load("edit");
  return json(await fn(family.id));
}

/** The language of names in shopping lists: `?lang=`, else the request's Accept-Language. */
function lang(ctx: Ctx): "en" | "de" {
  const asked = ctx.url.searchParams.get("lang") ?? ctx.req.headers.get("accept-language") ?? "";
  return asked.trim().toLowerCase().startsWith("de") ? "de" : "en";
}

function planResponse(db: Db, familyId: string) {
  const plan = getMealPlanView(db, familyId);
  const tags = listTags(db, familyId);
  if (!plan || plan.iterations.length === 0) return { plan, away: {}, tags };
  const from = plan.iterations.reduce((min, it) => (it.startDate < min ? it.startDate : min), plan.iterations[0].startDate);
  const to = plan.iterations.reduce((max, it) => (it.endDate > max ? it.endDate : max), plan.iterations[0].endDate);
  return { plan, away: Object.fromEntries(awayDays(db, familyId, from, to)), tags };
}

function nextIteration(ctx: Ctx, familyId: string) {
  const plan = ctx.db.select().from(mealPlans).where(eq(mealPlans.familyId, familyId)).get();
  const latest = plan
    ? ctx.db
        .select({ id: planIterations.id })
        .from(planIterations)
        .where(eq(planIterations.mealPlanId, plan.id))
        .orderBy(desc(planIterations.startDate))
        .get()
    : undefined;
  const before: IterationSnapshot | null = latest ? snapshotIteration(ctx.db, familyId, latest.id) : null;
  const { iterationId } = generateNextIteration(ctx.db, familyId, ctx.now);
  return { iterationId, undo: { restore: before ? [before] : [], remove: [iterationId] } };
}

/** Swaps a meal's recipe (its leftover days follow) or removes it (with its leftovers); the
 *  iteration's shopping lists are made anew, keeping ticks and items added by hand. */
function changeEntry(db: Db, familyId: string, entryId: string, change: { swap: string } | { remove: true }) {
  const entry = db
    .select({ id: mealPlanEntries.id, iterationId: mealPlanEntries.iterationId, isLeftover: mealPlanEntries.isLeftover })
    .from(mealPlanEntries)
    .innerJoin(planIterations, eq(planIterations.id, mealPlanEntries.iterationId))
    .innerJoin(mealPlans, eq(mealPlans.id, planIterations.mealPlanId))
    .where(and(eq(mealPlanEntries.id, entryId), eq(mealPlans.familyId, familyId)))
    .get();
  if (!entry) throw new AuthError(404, "Meal not found");
  if ("swap" in change) {
    const recipe = db
      .select({ id: recipes.id })
      .from(recipes)
      .where(and(eq(recipes.id, change.swap), eq(recipes.familyId, familyId)))
      .get();
    if (!recipe) throw new AuthError(404, "Recipe not found");
  }
  const before = snapshotIteration(db, familyId, entry.iterationId);
  db.transaction(() => {
    const generated = regenerate(db, familyId, entry.iterationId); // what the old meals make
    if ("swap" in change) {
      if (entry.isLeftover) {
        // A leftover day becomes a meal of its own.
        db.update(mealPlanEntries)
          .set({ recipeId: change.swap, isLeftover: false, sourceEntryId: null })
          .where(eq(mealPlanEntries.id, entryId))
          .run();
      } else {
        db.update(mealPlanEntries).set({ recipeId: change.swap }).where(eq(mealPlanEntries.id, entryId)).run();
        db.update(mealPlanEntries)
          .set({ recipeId: change.swap })
          .where(and(eq(mealPlanEntries.sourceEntryId, entryId), eq(mealPlanEntries.isLeftover, true)))
          .run();
      }
    } else {
      if (!entry.isLeftover) {
        db.delete(mealPlanEntries)
          .where(and(eq(mealPlanEntries.sourceEntryId, entryId), eq(mealPlanEntries.isLeftover, true)))
          .run();
      }
      db.delete(mealPlanEntries).where(eq(mealPlanEntries.id, entryId)).run();
    }
    regenerate(db, familyId, entry.iterationId);
    carryOver(db, entry.iterationId, before, generated);
  });
  return { iterationId: entry.iterationId, undo: { restore: [before], remove: [] } };
}

/** The family's iteration with its days and the plan's servings; else a 404. */
function ownedIteration(db: Db, familyId: string, iterationId: string) {
  const it = db
    .select({ id: planIterations.id, start: planIterations.startDate, end: planIterations.endDate, servings: mealPlans.servings })
    .from(planIterations)
    .innerJoin(mealPlans, eq(mealPlans.id, planIterations.mealPlanId))
    .where(and(eq(planIterations.id, iterationId), eq(mealPlans.familyId, familyId)))
    .get();
  if (!it) throw new AuthError(404, "Iteration not found");
  return it;
}

function checkInIteration(it: { start: string; end: string }, date: string) {
  if (date < it.start || date > it.end) throw new AuthError(422, "The day is not in the iteration");
}

/** Puts a recipe as the lunch on a day of the iteration that has none (409 if it has). */
function addEntry(db: Db, familyId: string, iterationId: string, input: { date: string; recipeId: string }) {
  const it = ownedIteration(db, familyId, iterationId);
  const recipe = db
    .select({ id: recipes.id })
    .from(recipes)
    .where(and(eq(recipes.id, input.recipeId), eq(recipes.familyId, familyId)))
    .get();
  if (!recipe) throw new AuthError(404, "Recipe not found");
  checkInIteration(it, input.date);
  const taken = db
    .select({ id: mealPlanEntries.id })
    .from(mealPlanEntries)
    .where(and(eq(mealPlanEntries.iterationId, iterationId), eq(mealPlanEntries.date, input.date), eq(mealPlanEntries.mealType, "LUNCH")))
    .get();
  if (taken) throw new AuthError(409, "That day already has a meal");
  const before = snapshotIteration(db, familyId, iterationId);
  db.transaction(() => {
    const generated = regenerate(db, familyId, iterationId);
    db.insert(mealPlanEntries)
      .values({
        id: randomUUID(),
        iterationId,
        date: input.date,
        mealType: "LUNCH",
        recipeId: recipe.id,
        servings: it.servings,
        isLeftover: false,
        sourceEntryId: null,
        isLocked: false,
      })
      .run();
    regenerate(db, familyId, iterationId);
    carryOver(db, iterationId, before, generated);
  });
  return { iterationId, undo: { restore: [before], remove: [] } };
}

/** Moves a meal to another day of its iteration; the meal of that day, if any, takes its day.
 *  A leftover that ends up on or before the day of its meal becomes a meal of its own. */
function moveEntry(db: Db, familyId: string, entryId: string, date: string) {
  const entry = db
    .select({ id: mealPlanEntries.id, iterationId: mealPlanEntries.iterationId, date: mealPlanEntries.date, mealType: mealPlanEntries.mealType })
    .from(mealPlanEntries)
    .innerJoin(planIterations, eq(planIterations.id, mealPlanEntries.iterationId))
    .innerJoin(mealPlans, eq(mealPlans.id, planIterations.mealPlanId))
    .where(and(eq(mealPlanEntries.id, entryId), eq(mealPlans.familyId, familyId)))
    .get();
  if (!entry) throw new AuthError(404, "Meal not found");
  const it = ownedIteration(db, familyId, entry.iterationId);
  checkInIteration(it, date);
  if (date === entry.date) return { iterationId: entry.iterationId, undo: null };
  const before = snapshotIteration(db, familyId, entry.iterationId);
  db.transaction(() => {
    const generated = regenerate(db, familyId, entry.iterationId);
    const other = db
      .select({ id: mealPlanEntries.id })
      .from(mealPlanEntries)
      .where(
        and(
          eq(mealPlanEntries.iterationId, entry.iterationId),
          eq(mealPlanEntries.date, date),
          eq(mealPlanEntries.mealType, entry.mealType),
        ),
      )
      .all();
    if (other.length) {
      db.update(mealPlanEntries).set({ date: entry.date }).where(inArray(mealPlanEntries.id, other.map((o) => o.id))).run();
    }
    db.update(mealPlanEntries).set({ date }).where(eq(mealPlanEntries.id, entryId)).run();
    // Leftovers now on or before the day of their meal stand on their own.
    const all = db
      .select({ id: mealPlanEntries.id, date: mealPlanEntries.date, isLeftover: mealPlanEntries.isLeftover, sourceEntryId: mealPlanEntries.sourceEntryId })
      .from(mealPlanEntries)
      .where(eq(mealPlanEntries.iterationId, entry.iterationId))
      .all();
    const dateOf = new Map(all.map((e) => [e.id, e.date]));
    const loose = all
      .filter((e) => e.isLeftover && e.sourceEntryId !== null && dateOf.has(e.sourceEntryId) && e.date <= dateOf.get(e.sourceEntryId)!)
      .map((e) => e.id);
    if (loose.length) {
      db.update(mealPlanEntries).set({ isLeftover: false, sourceEntryId: null }).where(inArray(mealPlanEntries.id, loose)).run();
    }
    regenerate(db, familyId, entry.iterationId);
    carryOver(db, entry.iterationId, before, generated);
  });
  return { iterationId: entry.iterationId, undo: { restore: [before], remove: [] } };
}

type ItemKey = string; // `${shoppingDate}|${ingredientId}|${unitId}`
const keyOf = (date: string | null, ingredientId: number, unitId: number): ItemKey => `${date ?? ""}|${ingredientId}|${unitId}`;

/** Makes the iteration's shopping lists from its meals; returns the generated quantities. */
function regenerate(db: Db, familyId: string, iterationId: string): Map<ItemKey, Decimal> {
  const it = db
    .select({ start: planIterations.startDate, end: planIterations.endDate, day1: mealPlans.shoppingDay1, day2: mealPlans.shoppingDay2 })
    .from(planIterations)
    .innerJoin(mealPlans, eq(mealPlans.id, planIterations.mealPlanId))
    .where(and(eq(planIterations.id, iterationId), eq(mealPlans.familyId, familyId)))
    .get()!;
  generateShoppingListsForIteration(db, {
    iterationId,
    startDate: it.start,
    endDate: it.end,
    shoppingDays: [it.day1, it.day2].filter((d): d is number => d !== null),
  });
  const out = new Map<ItemKey, Decimal>();
  for (const row of listItems(db, iterationId)) out.set(keyOf(row.date, row.ingredientId, row.unitId), new Decimal(row.quantity));
  return out;
}

function listItems(db: Db, iterationId: string) {
  return db
    .select({
      id: shoppingListItems.id,
      listId: shoppingLists.id,
      date: shoppingLists.shoppingDate,
      ingredientId: shoppingListItems.ingredientId,
      unitId: shoppingListItems.unitId,
      quantity: shoppingListItems.quantity,
    })
    .from(shoppingListItems)
    .innerJoin(shoppingLists, eq(shoppingLists.id, shoppingListItems.shoppingListId))
    .where(eq(shoppingLists.iterationId, iterationId))
    .all();
}

/** After the lists were made anew: puts back the ticks of `before` and what was added by hand
 *  (an item's quantity beyond what the old meals made), per shopping day, ingredient and unit. */
function carryOver(db: Db, iterationId: string, before: IterationSnapshot, oldGenerated: Map<ItemKey, Decimal>) {
  // Per key: what the list had (an item ticked before and one added later may share a key)
  // and whether all of it was ticked.
  const had = new Map<ItemKey, { quantity: Decimal; checked: boolean }>();
  for (const list of before.lists) {
    for (const item of list.items) {
      const key = keyOf(list.shoppingDate, item.ingredientId, item.unitId);
      let quantity: Decimal;
      try {
        quantity = new Decimal(item.quantity);
      } catch {
        quantity = new Decimal(0);
      }
      const prev = had.get(key);
      had.set(key, {
        quantity: (prev?.quantity ?? new Decimal(0)).plus(quantity),
        checked: (prev?.checked ?? true) && item.isChecked,
      });
    }
  }
  const checked = new Set<ItemKey>();
  const extra = new Map<ItemKey, Decimal>();
  for (const [key, h] of had) {
    if (h.checked) checked.add(key);
    const left = h.quantity.minus(oldGenerated.get(key) ?? new Decimal(0));
    if (left.gt(0)) extra.set(key, left);
  }
  const now = listItems(db, iterationId);
  const lists = db.select().from(shoppingLists).where(eq(shoppingLists.iterationId, iterationId)).all();
  const listByDate = new Map(lists.map((l) => [l.shoppingDate ?? "", l.id]));
  const ticked: string[] = [];
  for (const row of now) {
    const key = keyOf(row.date, row.ingredientId, row.unitId);
    const add = extra.get(key);
    if (add) {
      const sum = quantize2(new Decimal(row.quantity).plus(add)).toString();
      db.update(shoppingListItems).set({ quantity: sum }).where(eq(shoppingListItems.id, row.id)).run();
      extra.delete(key);
    }
    if (checked.has(key)) ticked.push(row.id);
  }
  if (ticked.length) db.update(shoppingListItems).set({ isChecked: true }).where(inArray(shoppingListItems.id, ticked)).run();
  for (const [key, quantity] of extra) {
    const [date, ingredientId, unitId] = key.split("|");
    const listId = listByDate.get(date);
    if (!listId) continue; // that shopping day is gone
    db.insert(shoppingListItems)
      .values({
        id: randomUUID(),
        shoppingListId: listId,
        ingredientId: Number(ingredientId),
        unitId: Number(unitId),
        quantity: quantize2(quantity).toString(),
        isChecked: checked.has(key),
      })
      .run();
  }
}

function shoppingOverview(ctx: Ctx, familyId: string) {
  const rows = ctx.db
    .select({
      id: shoppingLists.id,
      iterationId: shoppingLists.iterationId,
      status: planIterations.status,
      shoppingDate: shoppingLists.shoppingDate,
      itemCount: sql<number>`count(${shoppingListItems.id})`,
      checkedCount: sql<number>`coalesce(sum(case when ${shoppingListItems.isChecked} then 1 else 0 end), 0)`,
    })
    .from(shoppingLists)
    .innerJoin(planIterations, eq(planIterations.id, shoppingLists.iterationId))
    .innerJoin(mealPlans, eq(mealPlans.id, planIterations.mealPlanId))
    .leftJoin(shoppingListItems, eq(shoppingListItems.shoppingListId, shoppingLists.id))
    .where(eq(mealPlans.familyId, familyId))
    .groupBy(shoppingLists.id)
    .all()
    .sort((a, b) => (b.shoppingDate ?? "").localeCompare(a.shoppingDate ?? ""));
  return {
    lists: rows.map((r) => ({
      id: r.id,
      iterationId: r.iterationId,
      iterationStatus: r.status,
      shoppingDate: r.shoppingDate,
      itemCount: Number(r.itemCount),
      checkedCount: Number(r.checkedCount),
    })),
    latest: getLatestShoppingList(ctx.db, familyId, lang(ctx)),
  };
}

function addItem(db: Db, familyId: string, listId: string, input: z.infer<typeof addItemSchema>) {
  if (!db.select({ id: units.id }).from(units).where(eq(units.id, input.unitId)).get()) {
    throw new HttpError(404, "Unknown unit");
  }
  const low = input.name.toLowerCase();
  const existing = db
    .select({ id: ingredients.id })
    .from(ingredients)
    .where(sql`lower(${ingredients.nameEn}) = ${low} or lower(${ingredients.nameDe}) = ${low}`)
    .get();
  // Check the list (and the quantity) before a new ingredient is added to the shared table.
  if (!existing) {
    const owned = db
      .select({ id: shoppingLists.id })
      .from(shoppingLists)
      .innerJoin(planIterations, eq(planIterations.id, shoppingLists.iterationId))
      .innerJoin(mealPlans, eq(mealPlans.id, planIterations.mealPlanId))
      .where(and(eq(shoppingLists.id, listId), eq(mealPlans.familyId, familyId)))
      .get();
    if (!owned) throw new AuthError(404, "Shopping list not found");
    if (!/^\d+(\.\d+)?$/.test(input.quantity) || Number(input.quantity) <= 0) {
      throw new AuthError(422, "The quantity must be more than 0");
    }
  }
  const ingredientId =
    existing?.id ??
    findOrCreateIngredient(db, { nameEn: input.name, nameDe: input.name, category: input.category ?? "OTHER" }).id;
  return addShoppingItem(db, familyId, listId, { ingredientId, unitId: input.unitId, quantity: input.quantity });
}
