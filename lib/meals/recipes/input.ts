// A stored recipe as the input that saves it again (upsertRecipe): what the assistant's undo
// of a recipe change sends back, and the base a partial change starts from.

import { z } from "zod";
import type { RecipeDetail } from "@/lib/meals/queries/recipes";
import type { UpsertRecipeInput, UpsertStepInput } from "./upsert";

export function recipeToInput(recipe: RecipeDetail): UpsertRecipeInput {
  const orderOf = new Map(recipe.ingredients.map((ri) => [ri.id, ri.order]));
  const step = (method: "MANUAL" | "MACHINE") => (s: RecipeDetail["manualSteps"][number]): UpsertStepInput => ({
    method,
    stepNumber: s.stepNumber,
    instruction: s.instruction,
    programType: s.programType,
    temperature: s.temperature,
    durationSeconds: s.durationSeconds,
    speed: s.speed,
    turbo: s.turbo,
    direction: s.direction,
    weightGrams: s.weightGrams,
    ingredients: s.ingredients
      .filter((si) => orderOf.has(si.recipeIngredientId))
      .map((si) => ({ recipeIngredientOrder: orderOf.get(si.recipeIngredientId)!, quantity: si.quantity })),
  });
  return {
    title: recipe.title,
    description: recipe.description,
    listType: recipe.listType === "TO_TRY" ? "TO_TRY" : "KNOWN",
    defaultServings: recipe.defaultServings,
    prepTimeMinutes: recipe.prepTimeMinutes,
    cookTimeMinutes: recipe.cookTimeMinutes,
    leftoverDays: recipe.leftoverDays,
    ingredients: recipe.ingredients.map((ri) => ({
      ingredientId: ri.ingredientId,
      nameEn: "",
      nameDe: "",
      quantity: ri.quantity,
      unitId: ri.unitId,
      order: ri.order,
    })),
    steps: [...recipe.manualSteps.map(step("MANUAL")), ...recipe.machineSteps.map(step("MACHINE"))],
    tagIds: recipe.tags.map((t) => t.id),
  };
}

const intOrNull = z.number().int().nullable();

/** UpsertRecipeInput, checked (the REST route that puts a recipe back). */
export const upsertRecipeInputSchema = z.object({
  title: z.string().max(200),
  description: z.string().max(5000),
  listType: z.enum(["KNOWN", "TO_TRY"]),
  defaultServings: z.number().int().min(1).max(100),
  prepTimeMinutes: intOrNull,
  cookTimeMinutes: intOrNull,
  leftoverDays: intOrNull,
  ingredients: z
    .array(
      z.object({
        ingredientId: z.number().int().nullable(),
        nameEn: z.string().max(200),
        nameDe: z.string().max(200),
        quantity: z.string().max(40),
        unitId: z.number().int(),
        order: z.number().int(),
      }),
    )
    .max(200),
  steps: z
    .array(
      z.object({
        method: z.enum(["MANUAL", "MACHINE"]),
        stepNumber: z.number().int(),
        instruction: z.string().max(5000),
        programType: z.string().max(40),
        temperature: intOrNull,
        durationSeconds: intOrNull,
        speed: intOrNull,
        turbo: z.boolean(),
        direction: z.string().max(10),
        weightGrams: intOrNull,
        ingredients: z.array(z.object({ recipeIngredientOrder: z.number().int(), quantity: z.string().max(40) })).max(200),
      }),
    )
    .max(200),
  tagIds: z.array(z.string()).max(100),
});
