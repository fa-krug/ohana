// The assistant's meal tools: recipes (search, read, create, change), the meal plan (read,
// plan the next weeks or plan again, e.g. without fish) and what it needs from the shops (the
// shopping list itself is in the user's Reminders: reminders.ts). They work through lib/meals (every function scoped to the family); every change comes
// with undo steps against the family API's /meals routes (lib/meals/family-routes.ts).

import { and, eq, inArray, sql } from "drizzle-orm";
import { HttpError } from "@/lib/api/http";
import { ingredients, mealPlans, planIterations, recipeIngredients, recipes, units } from "@/lib/db/schema";
import type { Db } from "@/lib/db";
import { addDays, weekday } from "@/lib/meals/domain/dates";
import { fuzzyScore } from "@/lib/meals/domain/recipes/search";
import { awayDays } from "@/lib/meals/meal-plan/away";
import { generateNextIteration, renewIteration } from "@/lib/meals/meal-plan/iterations";
import { setupMealPlan } from "@/lib/meals/meal-plan/setup";
import { type IterationSnapshot, snapshotIteration } from "@/lib/meals/meal-plan/snapshot";
import { getMealPlanView } from "@/lib/meals/queries/meal-plan";
import { getRecipe, listRecipes, listTags, type RecipeDetail, type RecipeTagDto } from "@/lib/meals/queries/recipes";
import { recipeToInput } from "@/lib/meals/recipes/input";
import { upsertRecipe, type UpsertRecipeInput } from "@/lib/meals/recipes/upsert";
import { shoppingNeeds } from "@/lib/meals/shopping/needs";
import { fitting, type Tool, type ToolContext, type UndoStep } from "./common";

const WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
const MAX_RECIPES = 200;
const CATEGORIES = ["PRODUCE", "DAIRY", "MEAT", "PANTRY", "FROZEN", "OTHER"];

const PHRASES = {
  en: {
    recipeAdded: (t: string) => `Added the recipe “${t}”`,
    recipeChanged: (t: string) => `Changed the recipe “${t}”`,
    planNext: (from: string, to: string) => `Planned the meals ${from} – ${to}`,
    planAgain: (from: string, to: string) => `Planned the meals ${from} – ${to} again`,
    planSetUp: "Set up the meal plan",
  },
  de: {
    recipeAdded: (t: string) => `Rezept „${t}“ hinzugefügt`,
    recipeChanged: (t: string) => `Rezept „${t}“ geändert`,
    planNext: (from: string, to: string) => `Essen geplant: ${from} – ${to}`,
    planAgain: (from: string, to: string) => `Essen neu geplant: ${from} – ${to}`,
    planSetUp: "Essensplan eingerichtet",
  },
};

const enc = encodeURIComponent;
const str = (v: unknown) => (typeof v === "string" ? v.trim() : "");
const today = (ctx: ToolContext) => ctx.today ?? (ctx.now?.() ?? new Date()).toISOString().slice(0, 10);
const nowOf = (ctx: ToolContext) => ctx.now?.() ?? new Date();
const tagName = (t: RecipeTagDto, lang: string) => (lang === "de" ? t.nameDe : t.nameEn);

function intOrNull(v: unknown, field: string, min: number, max: number): number | null | undefined {
  if (v === undefined) return undefined;
  if (v === null || v === "") return null;
  const n = Number(v);
  if (!Number.isInteger(n) || n < min || n > max) {
    throw new HttpError(400, `${field} must be a whole number from ${min} to ${max}`);
  }
  return n;
}

/** The family's tags by id or name (English or German, any case); unknown ones fail with the
 *  names there are. */
function resolveTags(db: Db, familyId: string, refs: unknown, lang: string): RecipeTagDto[] {
  if (refs === undefined || refs === null) return [];
  const list = (Array.isArray(refs) ? refs : [refs]).map((r) => String(r).trim()).filter(Boolean);
  const tags = listTags(db, familyId);
  const out: RecipeTagDto[] = [];
  const unknown: string[] = [];
  for (const ref of list) {
    const low = ref.toLowerCase();
    const tag = tags.find((t) => t.id === ref || t.nameEn.toLowerCase() === low || t.nameDe.toLowerCase() === low);
    if (tag) {
      if (!out.includes(tag)) out.push(tag);
    } else unknown.push(ref);
  }
  if (unknown.length) {
    throw new HttpError(
      404,
      `Unknown tag ${unknown.map((u) => `"${u}"`).join(", ")}. The tags are: ${tags.map((t) => tagName(t, lang)).join(", ")}`,
    );
  }
  return out;
}

/** A recipe of the family by id or title (exact, else the best fuzzy match). */
function findRecipe(db: Db, familyId: string, ref: unknown): RecipeDetail {
  const r = str(ref);
  if (!r) throw new HttpError(400, "recipe is required (its id or title)");
  const byId = getRecipe(db, familyId, r);
  if (byId) return byId;
  const rows = db.select({ id: recipes.id, title: recipes.title }).from(recipes).where(eq(recipes.familyId, familyId)).all();
  const exact = rows.find((x) => x.title.toLowerCase() === r.toLowerCase());
  const best = exact ?? rows
    .map((x) => ({ x, score: fuzzyScore(x.title, r) }))
    .filter((m) => m.score > 0)
    .sort((a, b) => b.score - a.score)[0]?.x;
  const found = best && getRecipe(db, familyId, best.id);
  if (!found) throw new HttpError(404, `No recipe "${r}"`);
  return found;
}

const UNIT_ALIASES: Record<string, string> = {
  piece: "Stk", pieces: "Stk", pc: "Stk", pcs: "Stk", stück: "Stk", stueck: "Stk", x: "Stk", "": "Stk",
  tbsp: "EL", tablespoon: "EL", tablespoons: "EL", esslöffel: "EL",
  tsp: "TL", teaspoon: "TL", teaspoons: "TL", teelöffel: "TL",
  pinch: "Prise", pinches: "Prise", prisen: "Prise",
  gram: "g", grams: "g", gramm: "g", kilogram: "kg", kilograms: "kg", kilo: "kg",
  milliliter: "ml", millilitre: "ml", liter: "l", litre: "l", liters: "l",
};

/** A unit by abbreviation or name (English or German), with a few common aliases. */
function resolveUnit(db: Db, ref: unknown): { id: number; abbreviation: string } {
  const all = db.select().from(units).all();
  const low = str(ref).toLowerCase();
  const match = (s: string) =>
    all.find((u) => u.abbreviation.toLowerCase() === s.toLowerCase() || u.nameEn.toLowerCase() === s.toLowerCase() ||
      u.nameDe.toLowerCase() === s.toLowerCase());
  const unit = match(low) ?? (UNIT_ALIASES[low] !== undefined ? match(UNIT_ALIASES[low]) : undefined);
  if (!unit) {
    throw new HttpError(404, `Unknown unit "${str(ref)}". The units are: ${all.map((u) => `${u.abbreviation} (${u.nameEn})`).join(", ")}`);
  }
  return { id: unit.id, abbreviation: unit.abbreviation };
}

interface IngredientArg {
  name: string;
  nameEn: string;
  nameDe: string;
  category: string;
}

function ingredientArg(raw: unknown): IngredientArg {
  const o = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  const name = str(o.name) || str(o.nameEn) || str(o.nameDe);
  if (!name) throw new HttpError(400, "Every ingredient needs a name");
  const category = str(o.category).toUpperCase();
  return {
    name,
    nameEn: str(o.nameEn) || name,
    nameDe: str(o.nameDe) || name,
    category: CATEGORIES.includes(category) ? category : "OTHER",
  };
}

/** The shared ingredient by English or German name, if there is one. */
function existingIngredient(db: Db, arg: IngredientArg): number | null {
  for (const n of [arg.nameEn, arg.nameDe, arg.name]) {
    const row = db
      .select({ id: ingredients.id })
      .from(ingredients)
      .where(sql`lower(${ingredients.nameEn}) = ${n.toLowerCase()} or lower(${ingredients.nameDe}) = ${n.toLowerCase()}`)
      .get();
    if (row) return row.id;
  }
  return null;
}

function quantityOf(v: unknown): string {
  const s = String(v ?? "").trim().replace(",", ".");
  if (!/^\d+(\.\d+)?$/.test(s) || Number(s) <= 0) {
    throw new HttpError(400, `quantity must be a number above 0 (got "${String(v ?? "")}")`);
  }
  return s;
}

/** A recipe for the model: names instead of ids, in the user's language. */
function recipeView(db: Db, r: RecipeDetail, lang: string) {
  const ingIds = r.ingredients.map((i) => i.ingredientId);
  const unitIds = r.ingredients.map((i) => i.unitId);
  const ingById = new Map(
    (ingIds.length ? db.select().from(ingredients).where(inArray(ingredients.id, ingIds)).all() : []).map((i) => [i.id, i]),
  );
  const unitById = new Map(
    (unitIds.length ? db.select().from(units).where(inArray(units.id, unitIds)).all() : []).map((u) => [u.id, u]),
  );
  const name = (id: number) => {
    const i = ingById.get(id);
    return i ? (lang === "de" ? i.nameDe : i.nameEn) : "?";
  };
  const step = (s: RecipeDetail["manualSteps"][number]) =>
    s.instruction ||
    [s.programType, s.temperature !== null ? `${s.temperature}°C` : "", s.durationSeconds !== null ? `${s.durationSeconds}s` : "",
      s.speed !== null ? `speed ${s.speed}` : ""].filter(Boolean).join(" ");
  return {
    id: r.id,
    title: r.title,
    description: r.description,
    list: r.listType,
    servings: r.defaultServings,
    prepMinutes: r.prepTimeMinutes,
    cookMinutes: r.cookTimeMinutes,
    leftoverDays: r.leftoverDays,
    tags: r.tags.map((t) => tagName(t, lang)),
    ingredients: r.ingredients.map((i) => ({
      name: name(i.ingredientId),
      quantity: i.quantity,
      unit: unitById.get(i.unitId)?.abbreviation ?? "?",
    })),
    steps: r.manualSteps.map(step),
    machineSteps: r.machineSteps.map(step),
    hasPhoto: !!r.image,
  };
}

/** Ingredient names per recipe of the family (both languages). */
function ingredientNames(db: Db, familyId: string): Map<string, { en: string; de: string }[]> {
  const rows = db
    .select({ recipeId: recipeIngredients.recipeId, en: ingredients.nameEn, de: ingredients.nameDe })
    .from(recipeIngredients)
    .innerJoin(recipes, eq(recipes.id, recipeIngredients.recipeId))
    .innerJoin(ingredients, eq(ingredients.id, recipeIngredients.ingredientId))
    .where(eq(recipes.familyId, familyId))
    .all();
  const out = new Map<string, { en: string; de: string }[]>();
  for (const r of rows) out.set(r.recipeId, [...(out.get(r.recipeId) ?? []), { en: r.en, de: r.de }]);
  return out;
}

function planOf(db: Db, familyId: string) {
  return db.select().from(mealPlans).where(eq(mealPlans.familyId, familyId)).get();
}

/** The meals of the family's plan from `from` to `to`, with away days. */
function mealsBetween(db: Db, familyId: string, from: string, to: string, lang: string) {
  const view = getMealPlanView(db, familyId);
  const meals = (view?.iterations ?? [])
    .flatMap((it) => it.entries.map((e) => ({ ...e, iterationId: it.id })))
    .filter((e) => e.date >= from && e.date <= to)
    .sort((a, b) => a.date.localeCompare(b.date))
    .map((e) => ({
      date: e.date,
      weekday: WEEKDAYS[weekday(e.date)],
      recipeId: e.recipeId,
      recipe: e.recipeTitle,
      leftover: e.isLeftover,
      servings: e.servings,
    }));
  const away = [...awayDays(db, familyId, from, to)].map(([date, types]) => ({ date, types }));
  return { view, meals, away, lang };
}

const ingredientSpec = {
  type: "object",
  properties: {
    name: { type: "string", description: "The ingredient's name (e.g. Tomato)" },
    nameEn: { type: "string", description: "English name, if name is German" },
    nameDe: { type: "string", description: "German name" },
    quantity: { type: "number" },
    unit: { type: "string", description: "g, kg, ml, l, Stk (pieces), EL (tablespoon), TL (teaspoon), Prise (pinch)" },
    category: { type: "string", enum: CATEGORIES },
  },
  required: ["name", "quantity", "unit"],
};

export const mealTools: Record<string, Tool> = {
  list_recipes: {
    spec: {
      name: "list_recipes",
      description:
        "Lists or searches the family's recipes: title search (fuzzy), tags (any of them), list (KNOWN: recipes the family knows; TO_TRY: want to try), an ingredient they contain. withIngredients adds each recipe's ingredient names.",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string", description: "Words of the title" },
          tags: { type: "array", items: { type: "string" }, description: "Tag names or ids" },
          list: { type: "string", enum: ["KNOWN", "TO_TRY"] },
          ingredient: { type: "string", description: "Only recipes with this ingredient (part of its name)" },
          withIngredients: { type: "boolean" },
          offset: { type: "integer" },
        },
      },
    },
    async run(args, ctx) {
      const { db, familyId, lang } = ctx;
      const tags = resolveTags(db, familyId, args.tags, lang);
      const list = args.list === "KNOWN" || args.list === "TO_TRY" ? args.list : undefined;
      const res = listRecipes(db, familyId, {
        search: str(args.query) || undefined,
        tagIds: tags.length ? tags.map((t) => t.id) : undefined,
        listType: list,
        locale: lang,
        limit: 100_000,
      });
      const ingredient = str(args.ingredient).toLowerCase();
      const names = ingredient || args.withIngredients === true ? ingredientNames(db, familyId) : null;
      const items = ingredient
        ? res.items.filter((r) =>
          names!.get(r.id)?.some((n) => n.en.toLowerCase().includes(ingredient) || n.de.toLowerCase().includes(ingredient))
        )
        : res.items;
      const offset = Math.max(0, Math.floor(Number(args.offset)) || 0);
      const rows = items.slice(offset, offset + MAX_RECIPES).map((r) => ({
        id: r.id,
        title: r.title,
        list: r.listType,
        tags: r.tags.map((t) => tagName(t, lang)),
        servings: r.defaultServings,
        minutes: (r.prepTimeMinutes ?? 0) + (r.cookTimeMinutes ?? 0) || null,
        ...(args.withIngredients === true
          ? { ingredients: [...new Set((names!.get(r.id) ?? []).map((n) => (lang === "de" ? n.de : n.en)))] }
          : {}),
      }));
      const head = { total: items.length, offset };
      const shown = fitting(head, rows);
      return {
        result: { ...head, recipes: shown, ...(offset + shown.length < items.length ? { more: items.length - offset - shown.length } : {}) },
        summary: `${items.length} recipes`,
      };
    },
  },

  get_recipe: {
    spec: {
      name: "get_recipe",
      description: "Reads one recipe with its ingredients, steps and tags.",
      parameters: {
        type: "object",
        properties: { recipe: { type: "string", description: "Its id or title" } },
        required: ["recipe"],
      },
    },
    async run(args, { db, familyId, lang }) {
      const r = findRecipe(db, familyId, args.recipe);
      return { result: recipeView(db, r, lang), summary: r.title };
    },
  },

  save_recipe: {
    write: true,
    spec: {
      name: "save_recipe",
      description:
        'Adds a recipe, or changes one (give "recipe": its id or title; fields you leave out stay as they are). ingredients and steps replace the old ones when given (changing ingredients drops the amounts assigned to steps). New recipes go to the TO_TRY list unless list says KNOWN. Tags must be existing tag names.',
      parameters: {
        type: "object",
        properties: {
          recipe: { type: "string", description: "Only to change a recipe: its id or title" },
          title: { type: "string" },
          description: { type: "string" },
          list: { type: "string", enum: ["KNOWN", "TO_TRY"] },
          servings: { type: "integer" },
          prepMinutes: { type: "integer" },
          cookMinutes: { type: "integer" },
          leftoverDays: { type: "integer", description: "Days the leftovers last for (0–3)" },
          tags: { type: "array", items: { type: "string" } },
          ingredients: { type: "array", items: ingredientSpec },
          steps: { type: "array", items: { type: "string" }, description: "The instructions, in order" },
        },
      },
    },
    async run(args, ctx) {
      const { db, familyId, lang } = ctx;
      const before = args.recipe !== undefined ? findRecipe(db, familyId, args.recipe) : null;
      const base: UpsertRecipeInput = before
        ? recipeToInput(before)
        : {
            title: "",
            description: "",
            listType: "TO_TRY",
            defaultServings: 2,
            prepTimeMinutes: null,
            cookTimeMinutes: null,
            leftoverDays: null,
            ingredients: [],
            steps: [],
            tagIds: [],
          };
      const input: UpsertRecipeInput = { ...base };
      if (args.title !== undefined) input.title = str(args.title).slice(0, 200);
      if (!input.title) throw new HttpError(400, "title is required");
      if (args.description !== undefined) input.description = str(args.description).slice(0, 5000);
      if (args.list === "KNOWN" || args.list === "TO_TRY") input.listType = args.list;
      const servings = intOrNull(args.servings, "servings", 1, 50);
      if (servings) input.defaultServings = servings;
      const prep = intOrNull(args.prepMinutes, "prepMinutes", 0, 6000);
      if (prep !== undefined) input.prepTimeMinutes = prep;
      const cook = intOrNull(args.cookMinutes, "cookMinutes", 0, 6000);
      if (cook !== undefined) input.cookTimeMinutes = cook;
      const left = intOrNull(args.leftoverDays, "leftoverDays", 0, 3);
      if (left !== undefined) input.leftoverDays = left;
      if (args.tags !== undefined) input.tagIds = resolveTags(db, familyId, args.tags, lang).map((t) => t.id);
      if (args.ingredients !== undefined) {
        if (!Array.isArray(args.ingredients) || args.ingredients.length > 100) {
          throw new HttpError(400, "ingredients must be a list (at most 100)");
        }
        // Check everything before anything is added to the shared ingredients.
        const parsed = args.ingredients.map((raw) => {
          const o = (raw ?? {}) as Record<string, unknown>;
          return { arg: ingredientArg(o), quantity: quantityOf(o.quantity), unit: resolveUnit(db, o.unit) };
        });
        // Unknown ingredients are added by upsertRecipe, inside its transaction.
        input.ingredients = parsed.map((p, order) => ({
          ingredientId: existingIngredient(db, p.arg),
          nameEn: p.arg.nameEn,
          nameDe: p.arg.nameDe,
          quantity: p.quantity,
          unitId: p.unit.id,
          order,
        }));
        input.steps = input.steps.map((s) => ({ ...s, ingredients: [] }));
      }
      if (args.steps !== undefined) {
        if (!Array.isArray(args.steps) || args.steps.length > 100) throw new HttpError(400, "steps must be a list (at most 100)");
        const manual = args.steps.map((s) => str(s)).filter(Boolean).map((instruction, i) => ({
          method: "MANUAL" as const,
          stepNumber: i + 1,
          instruction,
          programType: "",
          temperature: null,
          durationSeconds: null,
          speed: null,
          turbo: false,
          direction: "",
          weightGrams: null,
          ingredients: [],
        }));
        input.steps = [...manual, ...input.steps.filter((s) => s.method === "MACHINE")];
      }
      const { id } = upsertRecipe(db, familyId, before?.id ?? null, input, nowOf(ctx));
      const undo: UndoStep[] = before
        ? [{ method: "PATCH", path: `/meals/recipes/${enc(id)}`, body: recipeToInput(before) }]
        : [{ method: "DELETE", path: `/meals/recipes/${enc(id)}` }];
      return {
        result: { ok: true, id, title: input.title, url: `/f/${familyId}/meals/recipes/${id}` },
        summary: input.title,
        change: {
          kind: "recipes",
          summary: before ? PHRASES[lang].recipeChanged(input.title) : PHRASES[lang].recipeAdded(input.title),
          undo,
        },
      };
    },
  },

  get_meal_plan: {
    spec: {
      name: "get_meal_plan",
      description:
        "Reads the meal plan (lunch per day) between two days, default the next 14 days from today: the meals (leftover: cooked on an earlier day), the days the family is away (no meal), the plan's iterations with their shopping days, and its settings (weeks per iteration, shopping days, servings, share of known recipes, excluded tags).",
      parameters: {
        type: "object",
        properties: {
          from: { type: "string", description: "YYYY-MM-DD" },
          to: { type: "string", description: "YYYY-MM-DD" },
        },
      },
    },
    async run(args, ctx) {
      const { db, familyId, lang } = ctx;
      const day = today(ctx);
      const from = /^\d{4}-\d{2}-\d{2}$/.test(str(args.from)) ? str(args.from) : day;
      const to = /^\d{4}-\d{2}-\d{2}$/.test(str(args.to)) ? str(args.to) : addDays(from, 13);
      if (from > to) throw new HttpError(400, "from must not be after to");
      const { view, meals, away } = mealsBetween(db, familyId, from, to, lang);
      if (!view) {
        return { result: { plan: null, note: "The family has no meal plan yet (plan_meals with action setup creates one)." }, summary: "No plan yet" };
      }
      const tags = listTags(db, familyId);
      return {
        result: {
          from,
          to,
          settings: {
            iterationWeeks: view.iterationWeeks,
            shoppingDays: view.shoppingDays.map((d) => WEEKDAYS[d]),
            servings: view.servings,
            knownRatio: Number(view.knownRatio),
            defaultLeftoverDays: view.defaultLeftoverDays,
            excludedTags: tags.filter((t) => view.excludedTagIds.includes(t.id)).map((t) => tagName(t, lang)),
          },
          iterations: view.iterations
            .filter((it) => it.endDate >= from && it.startDate <= to)
            .map((it) => ({
              id: it.id,
              from: it.startDate,
              to: it.endDate,
              status: it.status,
              shoppingDates: it.shoppingDates,
            })),
          latestIterationEnds: view.iterations.reduce((m, it) => (it.endDate > m ? it.endDate : m), ""),
          meals,
          away,
        },
        summary: `${meals.length} meals`,
      };
    },
  },

  plan_meals: {
    write: true,
    spec: {
      name: "plan_meals",
      description:
        'Plans meals. "next": the next iteration after the latest one (e.g. next week). "again": plans an iteration again with other recipes (default the latest). excludeTags leave recipes with those tags out of this planning only (e.g. ["Fish"] for "next week without fish"). "setup": creates the plan when the family has none (weeks 1–3, shoppingDays as weekdays, servings, knownRatio 0–1, leftoverDays 0–3, excludeTags for good). Days the family is away get no meal.',
      parameters: {
        type: "object",
        properties: {
          action: { type: "string", enum: ["next", "again", "setup"] },
          iteration: { type: "string", description: '"again": the iteration id (default the latest)' },
          excludeTags: { type: "array", items: { type: "string" } },
          weeks: { type: "integer" },
          shoppingDays: { type: "array", items: { type: "string" }, description: "Weekdays, e.g. [\"Saturday\"]" },
          servings: { type: "integer" },
          knownRatio: { type: "number" },
          leftoverDays: { type: "integer" },
        },
        required: ["action"],
      },
    },
    async run(args, ctx) {
      const { db, familyId, lang } = ctx;
      const tagIds = resolveTags(db, familyId, args.excludeTags, lang).map((t) => t.id);
      const plan = planOf(db, familyId);
      const now = nowOf(ctx);
      let iterationId: string;
      let undo: UndoStep[];
      let summary: (from: string, to: string) => string;
      switch (args.action) {
        case "setup": {
          if (plan) throw new HttpError(409, 'The family has a meal plan already: use "next" or "again" (its settings are on the plan page)');
          const days = (Array.isArray(args.shoppingDays) ? args.shoppingDays : [args.shoppingDays ?? "Saturday"]).map((d) => {
            const s = String(d).trim().toLowerCase();
            const i = WEEKDAYS.findIndex((w) => w.toLowerCase() === s || w.toLowerCase().slice(0, 3) === s.slice(0, 3));
            if (i < 0) throw new HttpError(400, `Unknown weekday "${d}"`);
            return i;
          });
          ({ iterationId } = setupMealPlan(db, familyId, {
            iterationWeeks: intOrNull(args.weeks, "weeks", 1, 3) ?? 1,
            shoppingDays: days,
            servings: intOrNull(args.servings, "servings", 1, 12) ?? 2,
            knownRatio: Math.min(1, Math.max(0, Number(args.knownRatio ?? 0.7) || 0)),
            defaultLeftoverDays: intOrNull(args.leftoverDays, "leftoverDays", 0, 3) ?? 1,
            excludedTagIds: tagIds,
          }, now));
          undo = [{ method: "DELETE", path: "/meals/plan" }];
          summary = () => PHRASES[lang].planSetUp;
          break;
        }
        case "next": {
          if (!plan) throw new HttpError(404, 'The family has no meal plan yet: set it up first (action "setup")');
          const latest = db
            .select({ id: planIterations.id })
            .from(planIterations)
            .where(eq(planIterations.mealPlanId, plan.id))
            .orderBy(sql`${planIterations.startDate} desc`)
            .get();
          const before: IterationSnapshot | null = latest ? snapshotIteration(db, familyId, latest.id) : null;
          ({ iterationId } = generateNextIteration(db, familyId, now, undefined, { excludedTagIds: tagIds }));
          undo = [{ method: "POST", path: "/meals/plan/restore", body: { restore: before ? [before] : [], remove: [iterationId] } }];
          summary = PHRASES[lang].planNext;
          break;
        }
        case "again": {
          if (!plan) throw new HttpError(404, 'The family has no meal plan yet: set it up first (action "setup")');
          const id = str(args.iteration) ||
            db
              .select({ id: planIterations.id })
              .from(planIterations)
              .where(eq(planIterations.mealPlanId, plan.id))
              .orderBy(sql`${planIterations.startDate} desc`)
              .get()?.id;
          if (!id) throw new HttpError(404, 'The plan has no iteration yet: use "next"');
          const before = snapshotIteration(db, familyId, id);
          renewIteration(db, familyId, id, undefined, { excludedTagIds: tagIds });
          iterationId = id;
          undo = [{ method: "POST", path: "/meals/plan/restore", body: { restore: [before], remove: [] } }];
          summary = PHRASES[lang].planAgain;
          break;
        }
        default:
          throw new HttpError(400, "action must be next, again or setup");
      }
      const it = db
        .select({ from: planIterations.startDate, to: planIterations.endDate })
        .from(planIterations)
        .innerJoin(mealPlans, eq(mealPlans.id, planIterations.mealPlanId))
        .where(and(eq(planIterations.id, iterationId), eq(mealPlans.familyId, familyId)))
        .get()!;
      const { meals, away } = mealsBetween(db, familyId, it.from, it.to, lang);
      return {
        result: { ok: true, iterationId, from: it.from, to: it.to, meals, away },
        summary: `${it.from} – ${it.to}`,
        change: { kind: "plan", summary: summary(it.from, it.to), undo },
      };
    },
  },

  get_shopping_items: {
    spec: {
      name: "get_shopping_items",
      description:
        "Works out what the meal plan needs from the shops: per shopping day from `from` on (default today), the ingredients of the meals until the next shopping day (not the leftovers), summed (name, quantity, unit, category). Ohana keeps no shopping list: the app puts these items into the shopping list in the user's Reminders.",
      parameters: { type: "object", properties: { from: { type: "string", description: "YYYY-MM-DD" } } },
    },
    async run(args, ctx) {
      const from = /^\d{4}-\d{2}-\d{2}$/.test(str(args.from)) ? str(args.from) : today(ctx);
      const days = shoppingNeeds(ctx.db, ctx.familyId, { from, locale: ctx.lang });
      const items = days.reduce((n, d) => n + d.items.length, 0);
      return {
        result: days.length
          ? { from, days }
          : { from, days, note: planOf(ctx.db, ctx.familyId) ? "Nothing to buy for the planned meals from then on." : "The family has no meal plan yet." },
        summary: `${items} ${items === 1 ? "item" : "items"}, ${days.length} ${days.length === 1 ? "day" : "days"}`,
      };
    },
  },
};

/** The family's meal tags in short, for the instructions (in the user's language). */
export function mealTagNames(db: Db, familyId: string, lang: string): string {
  return listTags(db, familyId).map((t) => tagName(t, lang)).join(", ");
}
