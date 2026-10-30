// cookless: tags, recipes (with their photos), meal plans and shopping lists → Meals.
//
// Ingredients and units are shared seed data in both apps, but their ids differ: a cookless
// ingredient is matched by its English name (case-insensitive), a unit by its abbreviation,
// as Ohana's seed does; one Ohana doesn't know yet is added. Rows with an integer id
// (recipe ingredients, steps, …) get new ids; the uuid ones keep theirs.
import { copyFileSync, constants, existsSync, mkdirSync, readFileSync, statSync } from "node:fs";
import { dirname, resolve, sep } from "node:path";
import { eq, sql } from "drizzle-orm";
import {
  cookingSteps,
  ingredients,
  mealPlanEntries,
  mealPlanExcludedTags,
  mealPlans,
  mealTags,
  planIterations,
  recipeIngredients,
  recipes,
  recipeTags,
  shoppingListItems,
  shoppingLists,
  stepIngredients,
  units,
} from "@/lib/db/schema";
import { all, bool, int, intOrNull, sec, str, strOrNull } from "../sqlite";
import type { CooklessSource, ImportContext } from "../types";

function inside(root: string, rel: string): string | null {
  const abs = resolve(root, rel);
  return abs.startsWith(resolve(root) + sep) ? abs : null;
}

class SharedData {
  private ingredientIds = new Map<number, number>();
  private unitIds = new Map<number, number>();
  private readonly srcIngredients: Map<number, Record<string, unknown>>;
  private readonly srcUnits: Map<number, Record<string, unknown>>;

  constructor(private readonly ctx: ImportContext, src: CooklessSource) {
    this.srcIngredients = new Map(all(src.db, "SELECT * FROM ingredients").map((r) => [int(r.id), r]));
    this.srcUnits = new Map(all(src.db, "SELECT * FROM units").map((r) => [int(r.id), r]));
  }

  ingredient(id: number): number | null {
    const known = this.ingredientIds.get(id);
    if (known !== undefined) return known;
    const r = this.srcIngredients.get(id);
    if (!r) return null;
    const nameEn = str(r.name_en);
    const { db } = this.ctx;
    const existing = db
      .select({ id: ingredients.id })
      .from(ingredients)
      .where(sql`lower(${ingredients.nameEn}) = ${nameEn.toLowerCase()}`)
      .get();
    const target =
      existing?.id ??
      db
        .insert(ingredients)
        .values({ nameEn, nameDe: str(r.name_de), category: str(r.category, "OTHER") })
        .returning({ id: ingredients.id })
        .get().id;
    this.ingredientIds.set(id, target);
    return target;
  }

  unit(id: number, depth = 0): number | null {
    const known = this.unitIds.get(id);
    if (known !== undefined) return known;
    const r = this.srcUnits.get(id);
    if (!r) return null;
    const { db } = this.ctx;
    const abbreviation = str(r.abbreviation);
    const existing = db.select({ id: units.id }).from(units).where(eq(units.abbreviation, abbreviation)).get();
    let target = existing?.id;
    if (target === undefined) {
      const base = r.base_unit_id !== null && depth < 5 ? this.unit(int(r.base_unit_id), depth + 1) : null;
      target = db
        .insert(units)
        .values({
          nameEn: str(r.name_en),
          nameDe: str(r.name_de),
          abbreviation,
          baseUnitId: base,
          conversionFactor: str(r.conversion_factor, "1"),
        })
        .returning({ id: units.id })
        .get().id;
    }
    this.unitIds.set(id, target);
    return target;
  }
}

/** The recipe's photo: copied from cookless's media folder to the same relative path under
 *  MEDIA_ROOT (`recipes/<id>_<ts>.webp`, what Ohana writes too). Missing: the recipe loses it. */
function photo(ctx: ImportContext, src: CooklessSource, recipeId: string, rel: string): string {
  if (!rel) return "";
  const missing = (why: string) => {
    ctx.report.media.missing.push(`${rel} (${why})`);
    return "";
  };
  if (!src.mediaDir) return missing("no --cookless-media given");
  const from = inside(src.mediaDir, rel);
  const to = inside(ctx.mediaRoot, rel);
  if (!from || !to) return missing("path outside the media folder");
  if (!existsSync(from) || !statSync(from).isFile()) return missing("file not found");
  if (!ctx.dryRun) {
    if (existsSync(to)) {
      // Left by an earlier attempt? Only the very same file is accepted.
      if (!readFileSync(to).equals(readFileSync(from))) {
        throw new Error(`${to} exists already with other content (recipe ${recipeId})`);
      }
    } else {
      mkdirSync(dirname(to), { recursive: true });
      copyFileSync(from, to, constants.COPYFILE_EXCL);
      ctx.copiedFiles.push(to);
    }
  }
  ctx.report.media.copied++;
  return rel;
}

export function importCooklessMeals(ctx: ImportContext): void {
  const src = ctx.sources.cookless;
  if (!src) return;
  const { db } = ctx;
  const shared = new SharedData(ctx, src);
  const family = (householdId: unknown) => ctx.familyIds.cookless.get(str(householdId));

  // Tags (cookless `tags` → `meal_tags`).
  const tagIds = new Set<string>();
  for (const t of all(src.db, "SELECT * FROM tags")) {
    const familyId = family(t.household_id);
    if (!familyId) {
      ctx.skip("cookless", "tags", str(t.id), "its household isn't imported");
      continue;
    }
    db.insert(mealTags)
      .values({
        id: str(t.id),
        familyId,
        category: str(t.category),
        nameEn: str(t.name_en),
        nameDe: str(t.name_de),
        isDefault: bool(t.is_default),
      })
      .run();
    tagIds.add(str(t.id));
  }

  // Recipes.
  const recipeIds = new Set<string>();
  for (const r of all(src.db, "SELECT * FROM recipes ORDER BY created_at")) {
    const id = str(r.id);
    const familyId = family(r.household_id);
    if (!familyId) {
      ctx.skip("cookless", "recipes", str(r.title), "its household isn't imported");
      continue;
    }
    const createdAt = sec(r.created_at) ?? ctx.now;
    db.insert(recipes)
      .values({
        id,
        familyId,
        title: str(r.title),
        description: str(r.description),
        listType: str(r.list_type, "KNOWN"),
        defaultServings: int(r.default_servings, 2),
        prepTimeMinutes: intOrNull(r.prep_time_minutes),
        cookTimeMinutes: intOrNull(r.cook_time_minutes),
        leftoverDays: intOrNull(r.leftover_days),
        image: photo(ctx, src, id, str(r.image)),
        createdAt,
        updatedAt: sec(r.updated_at) ?? createdAt,
      })
      .run();
    recipeIds.add(id);
  }

  const recipeIngredientIds = new Map<number, number>();
  for (const ri of all(src.db, 'SELECT * FROM recipe_ingredients ORDER BY recipe_id, "order", id')) {
    if (!recipeIds.has(str(ri.recipe_id))) continue;
    const ingredientId = shared.ingredient(int(ri.ingredient_id));
    const unitId = shared.unit(int(ri.unit_id));
    if (ingredientId === null || unitId === null) {
      ctx.skip("cookless", "recipe_ingredients", str(ri.id), "unknown ingredient or unit");
      continue;
    }
    const row = db
      .insert(recipeIngredients)
      .values({ recipeId: str(ri.recipe_id), ingredientId, quantity: str(ri.quantity, "0"), unitId, order: int(ri.order) })
      .returning({ id: recipeIngredients.id })
      .get();
    recipeIngredientIds.set(int(ri.id), row.id);
  }

  const stepIds = new Map<number, number>();
  for (const s of all(src.db, "SELECT * FROM cooking_steps ORDER BY recipe_id, step_number, id")) {
    if (!recipeIds.has(str(s.recipe_id))) continue;
    const row = db
      .insert(cookingSteps)
      .values({
        recipeId: str(s.recipe_id),
        method: str(s.method, "MANUAL"),
        stepNumber: int(s.step_number),
        instruction: str(s.instruction),
        programType: str(s.program_type),
        temperature: intOrNull(s.temperature),
        durationSeconds: intOrNull(s.duration_seconds),
        speed: intOrNull(s.speed),
        turbo: bool(s.turbo),
        direction: str(s.direction),
        weightGrams: intOrNull(s.weight_grams),
      })
      .returning({ id: cookingSteps.id })
      .get();
    stepIds.set(int(s.id), row.id);
  }

  for (const si of all(src.db, "SELECT * FROM step_ingredients ORDER BY id")) {
    const stepId = stepIds.get(int(si.step_id));
    const recipeIngredientId = recipeIngredientIds.get(int(si.recipe_ingredient_id));
    if (stepId === undefined || recipeIngredientId === undefined) continue; // its recipe was skipped
    db.insert(stepIngredients).values({ stepId, recipeIngredientId, quantity: str(si.quantity, "0") }).run();
  }

  for (const rt of all(src.db, "SELECT * FROM recipe_tags ORDER BY id")) {
    if (!recipeIds.has(str(rt.recipe_id)) || !tagIds.has(str(rt.tag_id))) continue;
    db.insert(recipeTags).values({ recipeId: str(rt.recipe_id), tagId: str(rt.tag_id) }).run();
  }

  // Meal plans, their iterations, entries and shopping lists.
  const planIds = new Set<string>();
  for (const p of all(src.db, "SELECT * FROM meal_plans")) {
    const familyId = family(p.household_id);
    if (!familyId) continue;
    db.insert(mealPlans)
      .values({
        id: str(p.id),
        familyId,
        iterationWeeks: int(p.iteration_weeks, 1),
        shoppingDay1: int(p.shopping_day_1, 5),
        shoppingDay2: intOrNull(p.shopping_day_2),
        servings: int(p.servings, 2),
        knownRatio: str(p.known_ratio, "0.7"),
        defaultLeftoverDays: int(p.default_leftover_days, 1),
        createdAt: sec(p.created_at) ?? ctx.now,
      })
      .run();
    planIds.add(str(p.id));
  }
  for (const x of all(src.db, "SELECT * FROM meal_plan_excluded_tags ORDER BY id")) {
    if (!planIds.has(str(x.meal_plan_id)) || !tagIds.has(str(x.tag_id))) continue;
    db.insert(mealPlanExcludedTags).values({ mealPlanId: str(x.meal_plan_id), tagId: str(x.tag_id) }).run();
  }

  const iterationIds = new Set<string>();
  for (const it of all(src.db, "SELECT * FROM plan_iterations ORDER BY created_at")) {
    if (!planIds.has(str(it.meal_plan_id))) continue;
    db.insert(planIterations)
      .values({
        id: str(it.id),
        mealPlanId: str(it.meal_plan_id),
        startDate: str(it.start_date),
        endDate: str(it.end_date),
        status: str(it.status, "ACTIVE"),
        createdAt: sec(it.created_at) ?? ctx.now,
      })
      .run();
    iterationIds.add(str(it.id));
  }

  const entries = all(src.db, "SELECT * FROM meal_plan_entries ORDER BY date, id").filter((e) =>
    iterationIds.has(str(e.iteration_id)),
  );
  const entryIds = new Set<string>();
  for (const e of entries) {
    if (!recipeIds.has(str(e.recipe_id))) {
      ctx.skip("cookless", "meal_plan_entries", str(e.id), "its recipe isn't imported");
      continue;
    }
    db.insert(mealPlanEntries)
      .values({
        id: str(e.id),
        iterationId: str(e.iteration_id),
        date: str(e.date),
        mealType: str(e.meal_type),
        recipeId: str(e.recipe_id),
        servings: int(e.servings, 2),
        isLeftover: bool(e.is_leftover),
        sourceEntryId: null, // set below, once every entry exists
        isLocked: bool(e.is_locked),
      })
      .run();
    entryIds.add(str(e.id));
  }
  for (const e of entries) {
    const source = strOrNull(e.source_entry_id);
    if (source && entryIds.has(str(e.id)) && entryIds.has(source)) {
      db.update(mealPlanEntries).set({ sourceEntryId: source }).where(eq(mealPlanEntries.id, str(e.id))).run();
    }
  }

  const listIds = new Set<string>();
  for (const l of all(src.db, "SELECT * FROM shopping_lists ORDER BY created_at")) {
    if (!iterationIds.has(str(l.iteration_id))) continue;
    db.insert(shoppingLists)
      .values({
        id: str(l.id),
        iterationId: str(l.iteration_id),
        shoppingDate: strOrNull(l.shopping_date),
        createdAt: sec(l.created_at) ?? ctx.now,
      })
      .run();
    listIds.add(str(l.id));
  }
  for (const item of all(src.db, "SELECT * FROM shopping_list_items")) {
    if (!listIds.has(str(item.shopping_list_id))) continue;
    const ingredientId = shared.ingredient(int(item.ingredient_id));
    const unitId = shared.unit(int(item.unit_id));
    if (ingredientId === null || unitId === null) {
      ctx.skip("cookless", "shopping_list_items", str(item.id), "unknown ingredient or unit");
      continue;
    }
    db.insert(shoppingListItems)
      .values({
        id: str(item.id),
        shoppingListId: str(item.shopping_list_id),
        ingredientId,
        quantity: str(item.quantity, "0"),
        unitId,
        isChecked: bool(item.is_checked),
      })
      .run();
  }
}
