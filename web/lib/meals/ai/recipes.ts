// The recipe generator's database side (port of cookless's app/api/recipes/generate/route.ts
// and lib/recipes/images.ts generateRecipeImageFromAI, scoped to a family): what the prompt
// gets from the family's recipes, tags and the shared ingredients and units; the tag and unit
// ids of what the model made up; and an AI photo for a stored recipe.

import { and, asc, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import {
  cookingSteps, ingredients, mealTags, recipeIngredients, recipes, recipeTags, units,
} from "@/lib/db/schema";
import { deleteImageFile, processToWebp, writeRecipeImage } from "@/lib/meals/images/storage";
import { buildGenerationPrompt, buildImagePrompt, type PromptRecipe, selectReferenceRecipes } from "./prompt";
import type { VerifiedRecipe } from "./verify";

const MAX_REFERENCE_RECIPES = 10;
const MAX_INGREDIENTS = 200;

/** A generated recipe as the generate page gets it (cookless's GeneratedRecipeData). */
export interface GeneratedIngredient {
  name_en: string;
  name_de: string;
  category?: string;
  quantity?: number | string;
  unit_abbreviation?: string;
  unit_id?: number | null;
  order?: number;
}
export interface GeneratedStep {
  step_number: number;
  instruction?: string;
  program_type?: string;
  temperature?: number | null;
  duration_seconds?: number | null;
  speed?: number | null;
  turbo?: boolean;
  direction?: string;
  weight_grams?: number | null;
}
export interface GeneratedRecipeData {
  title: string;
  description?: string;
  default_servings?: number;
  prep_time_minutes?: number | null;
  cook_time_minutes?: number | null;
  leftover_days?: number | null;
  ingredients?: GeneratedIngredient[];
  manual_steps?: GeneratedStep[];
  machine_steps?: GeneratedStep[];
  tag_names_en?: string[];
  tag_ids?: string[];
}

export interface PromptInput {
  count: number;
  tagIds: string[];
  freeText: string;
  language: string;
}

/** The generator's prompt for the family: its tags, its recipes as style references (those
 *  with the required tags first) and titles not to repeat, the shared ingredients and units. */
export function recipePrompt(db: Db, familyId: string, input: PromptInput): string {
  const ingredientRows = db
    .select({ nameEn: ingredients.nameEn, nameDe: ingredients.nameDe, category: ingredients.category })
    .from(ingredients)
    .limit(MAX_INGREDIENTS)
    .all();
  const unitRows = db.select().from(units).all();
  const tagRows = db
    .select({ id: mealTags.id, nameEn: mealTags.nameEn, nameDe: mealTags.nameDe, category: mealTags.category })
    .from(mealTags)
    .where(eq(mealTags.familyId, familyId))
    .all();
  const recipeRows = db.select().from(recipes).where(eq(recipes.familyId, familyId)).all();
  const recipeTagRows = db
    .select({ recipeId: recipeTags.recipeId, tagId: recipeTags.tagId })
    .from(recipeTags)
    .innerJoin(recipes, eq(recipeTags.recipeId, recipes.id))
    .where(eq(recipes.familyId, familyId))
    .all();
  const tagIdsByRecipe = new Map<string, string[]>();
  for (const rt of recipeTagRows) tagIdsByRecipe.set(rt.recipeId, [...(tagIdsByRecipe.get(rt.recipeId) ?? []), rt.tagId]);
  const ownTagIds = input.tagIds.filter((id) => tagRows.some((t) => t.id === id));
  const selected = selectReferenceRecipes(
    recipeRows.map((r) => ({ id: r.id, tagIds: tagIdsByRecipe.get(r.id) ?? [] })),
    ownTagIds,
    MAX_REFERENCE_RECIPES,
  );
  const tagNameById = new Map(tagRows.map((t) => [t.id, t.nameEn]));
  const ingNameById = new Map(db.select({ id: ingredients.id, nameEn: ingredients.nameEn }).from(ingredients).all().map((i) => [i.id, i.nameEn]));
  const unitAbbrById = new Map(unitRows.map((u) => [u.id, u.abbreviation]));
  const referenceRecipes: PromptRecipe[] = selected.map((sel) => {
    const r = recipeRows.find((x) => x.id === sel.id)!;
    const ris = db.select().from(recipeIngredients).where(eq(recipeIngredients.recipeId, r.id)).orderBy(asc(recipeIngredients.order)).all();
    const steps = db.select().from(cookingSteps).where(eq(cookingSteps.recipeId, r.id)).all();
    return {
      title: r.title,
      defaultServings: r.defaultServings,
      prepTimeMinutes: r.prepTimeMinutes,
      cookTimeMinutes: r.cookTimeMinutes,
      leftoverDays: r.leftoverDays,
      tagNames: (tagIdsByRecipe.get(r.id) ?? []).map((id) => tagNameById.get(id) ?? "").filter(Boolean),
      ingredientLines: ris.map((ri) => `    ${ri.quantity} ${unitAbbrById.get(ri.unitId) ?? ""} ${ingNameById.get(ri.ingredientId) ?? ""}`),
      manualInstructions: steps.filter((s) => s.method === "MANUAL").map((s) => s.instruction),
      machineInstructions: steps.filter((s) => s.method === "MACHINE").map((s) => s.instruction),
    };
  });
  return buildGenerationPrompt({
    count: input.count,
    freeText: input.freeText,
    language: input.language,
    ingredients: ingredientRows,
    units: unitRows.map((u) => ({ abbreviation: u.abbreviation, nameEn: u.nameEn, nameDe: u.nameDe })),
    tags: tagRows,
    requiredTagIds: ownTagIds,
    referenceRecipes,
    allTitles: recipeRows.map((r) => r.title),
  });
}

/** Resolves a generated recipe's tag names to the family's tag ids and its units'
 *  abbreviations to unit ids (null: unknown, the ingredient is left out when saving). */
export function resolveGenerated(db: Db, familyId: string, r: VerifiedRecipe): GeneratedRecipeData {
  const tagIdByName = new Map(
    db.select({ id: mealTags.id, nameEn: mealTags.nameEn }).from(mealTags).where(eq(mealTags.familyId, familyId)).all()
      .map((t) => [t.nameEn.toLowerCase(), t.id]),
  );
  const unitIdByAbbr = new Map(db.select().from(units).all().map((u) => [u.abbreviation.toLowerCase(), u.id]));
  const step = (s: VerifiedRecipe["manual_steps"][number], i: number): GeneratedStep => ({
    ...s,
    step_number: s.step_number ?? i + 1,
    instruction: s.instruction ?? "",
  });
  return {
    title: r.title,
    description: r.description ?? "",
    default_servings: r.default_servings ?? 2,
    prep_time_minutes: r.prep_time_minutes ?? null,
    cook_time_minutes: r.cook_time_minutes ?? null,
    leftover_days: r.leftover_days ?? null,
    ingredients: r.ingredients.map((i, idx) => ({
      name_en: i.name_en,
      name_de: i.name_de ?? i.name_en,
      category: i.category ?? "OTHER",
      quantity: i.quantity,
      unit_abbreviation: i.unit_abbreviation ?? "",
      unit_id: unitIdByAbbr.get((i.unit_abbreviation ?? "").toLowerCase()) ?? null,
      order: i.order ?? idx,
    })),
    manual_steps: r.manual_steps.map(step),
    machine_steps: r.machine_steps.map(step),
    tag_names_en: r.tag_names_en ?? [],
    tag_ids: [...new Set((r.tag_names_en ?? []).map((n) => tagIdByName.get(n.toLowerCase())).filter((x): x is string => !!x))],
  };
}

/** The photo prompt for a generated recipe (its title and first ten ingredients). */
export function imagePromptOf(data: GeneratedRecipeData): string {
  return buildImagePrompt(data.title, (data.ingredients ?? []).slice(0, 10).map((i) => i.name_en));
}

/** Makes an AI photo for one of the family's recipes and stores it (replacing the old one). */
export async function generateRecipeImage(
  db: Db,
  familyId: string,
  recipeId: string,
  now: Date,
  generate: (prompt: string) => Promise<Buffer>,
): Promise<void> {
  const recipe = db
    .select({ title: recipes.title, oldImage: recipes.image })
    .from(recipes)
    .where(and(eq(recipes.id, recipeId), eq(recipes.familyId, familyId)))
    .get();
  if (!recipe) throw new AuthError(404, "Recipe not found");
  const names = db
    .select({ nameEn: ingredients.nameEn })
    .from(recipeIngredients)
    .innerJoin(ingredients, eq(recipeIngredients.ingredientId, ingredients.id))
    .where(eq(recipeIngredients.recipeId, recipeId))
    .orderBy(asc(recipeIngredients.order))
    .all()
    .slice(0, 10)
    .map((r) => r.nameEn);
  const bytes = await generate(buildImagePrompt(recipe.title, names));
  let webp: Buffer;
  try {
    webp = await processToWebp(bytes);
  } catch {
    throw new AuthError(502, "The image model returned no usable image");
  }
  const rel = writeRecipeImage(recipeId, webp, now);
  // The recipe may have gone meanwhile (the model takes a while).
  const res = db.update(recipes).set({ image: rel, updatedAt: now }).where(and(eq(recipes.id, recipeId), eq(recipes.familyId, familyId))).run();
  if (!res.changes) {
    deleteImageFile(rel);
    throw new AuthError(404, "Recipe not found");
  }
  if (recipe.oldImage) deleteImageFile(recipe.oldImage);
}
