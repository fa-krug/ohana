// Routes of the family API for the native app (apple/): /meals/plan/... and /meals/shopping:
// reads and changes of the meal plan, and what it needs from the shops.
// Registered before the meals' other routes; null for paths that aren't its own (handleMeals
// keeps POST /meals/plan/restore and DELETE /meals/plan).
//
//   GET    /meals/plan                          {plan: MealPlanView | null, away: {day: [type names]}, tags}
//   POST   /meals/plan/setup                    SetupPlanInput → {iterationId}            (the plan page's form)
//   POST   /meals/plan/next                     → {iterationId, undo}                      ("Start next iteration")
//   POST   /meals/plan/iterations/{id}/renew    → {iterationId, undo}                      ("Refresh")
//   POST   /meals/plan/iterations/{id}/entries  {date, recipeId} → {iterationId, undo}     (a recipe on a day without lunch; 409 if it has one)
//   PATCH  /meals/plan/entries/{id}             {recipeId} → {iterationId, undo}           (swap a meal)
//   DELETE /meals/plan/entries/{id}             → {iterationId, undo}                      (remove a meal)
//   POST   /meals/plan/entries/{id}/move        {date} → {iterationId, undo | null}        (to another day; that day's lunch takes its day)
//   GET    /meals/shopping?from=&lang=          {days: [{date, items: [ShoppingNeed]}]}    (what the plan needs per shopping day)
//
// `undo` is the body for POST /meals/plan/restore that puts the plan back as it was.
// Viewers read; changes need an editor. No shopping list is stored: GET /meals/shopping computes
// it from the plan (lib/meals/shopping/needs.ts), the app writes it into the user's Reminders.
// `from` (YYYY-MM-DD, default the server's today): shopping days on or after it.

import { randomUUID } from "node:crypto";
import { and, desc, eq, inArray } from "drizzle-orm";
import { z } from "zod";
import type { Db } from "@/lib/db";
import type { Ctx } from "@/lib/api/family-api";
import { json, readBody } from "@/lib/api/http";
import { AuthError } from "@/lib/auth/errors";
import { formatDate } from "@/lib/calendar/dates";
import { mealPlanEntries, mealPlans, planIterations, recipes } from "@/lib/db/schema";
import { awayDays } from "./meal-plan/away";
import { generateNextIteration, renewIteration } from "./meal-plan/iterations";
import { setupMealPlan } from "./meal-plan/setup";
import { type IterationSnapshot, snapshotIteration } from "./meal-plan/snapshot";
import { getMealPlanView } from "./queries/meal-plan";
import { listTags } from "./queries/recipes";
import { setupPlanSchema } from "./schemas/mutations";
import { shoppingNeeds } from "./shopping/needs";

const swapSchema = z.object({ recipeId: z.string().min(1).max(64) });
const day = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, "The date must be YYYY-MM-DD")
  .refine((d) => !Number.isNaN(Date.parse(`${d}T00:00:00Z`)) && new Date(`${d}T00:00:00Z`).toISOString().startsWith(d), "Unknown date");
const addEntrySchema = z.object({ date: day, recipeId: z.string().min(1).max(64) });
const moveEntrySchema = z.object({ date: day });

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
  if (area === "shopping" && m === "GET" && sub === undefined) {
    return view(ctx, (familyId) => ({ days: shoppingNeeds(ctx.db, familyId, { from: fromDay(ctx), locale: lang(ctx) }) }));
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

/** `?from=` (YYYY-MM-DD), else the server's today. */
function fromDay(ctx: Ctx): string {
  const from = ctx.url.searchParams.get("from");
  if (from === null || from === "") return formatDate(ctx.now);
  return day.parse(from);
}

/** The language of the ingredients' names: `?lang=`, else the request's Accept-Language. */
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

/** Swaps a meal's recipe (its leftover days follow) or removes it (with its leftovers). */
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
  });
  return { iterationId: entry.iterationId, undo: { restore: [before], remove: [] } };
}
