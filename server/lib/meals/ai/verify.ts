// What the model answered, checked: the recipes of the generator's JSON (cookless trusted
// Gemini's JSON mode; an OpenAI-compatible model may wrap the array in Markdown, an object or
// put strings where numbers go). Every recipe is validated with zod; one that doesn't fit is
// dropped instead of failing the whole answer.

import { z } from "zod";

const num = z.union([z.number(), z.string().trim().regex(/^\d+([.,]\d+)?$/).transform((s) => Number(s.replace(",", ".")))]);
const int = num.transform((n) => Math.round(n));
const optInt = int.nullable().optional().catch(null);
const text = (max: number) => z.string().trim().max(max);

const ingredientSchema = z.object({
  name_en: text(200).min(1),
  name_de: text(200).min(1).optional(),
  category: z.enum(["PRODUCE", "DAIRY", "MEAT", "PANTRY", "FROZEN", "OTHER"]).catch("OTHER").optional(),
  quantity: num.refine((n) => n > 0, "quantity must be above 0"),
  unit_abbreviation: text(20).optional().catch(""),
  order: int.optional().catch(undefined),
});

const stepSchema = z.object({
  step_number: int.optional().catch(undefined),
  instruction: text(5000).optional().catch(""),
  program_type: text(40).optional().catch(undefined),
  temperature: optInt,
  duration_seconds: optInt,
  speed: optInt,
  turbo: z.boolean().optional().catch(false),
  direction: text(10).optional().catch(""),
  weight_grams: optInt,
});

export const generatedRecipeSchema = z.object({
  title: text(200).min(1),
  description: text(5000).optional().catch(""),
  default_servings: int.refine((n) => n >= 1 && n <= 50).optional().catch(2),
  prep_time_minutes: optInt,
  cook_time_minutes: optInt,
  leftover_days: int.refine((n) => n >= 0 && n <= 3).nullable().optional().catch(null),
  ingredients: z.array(z.unknown()).max(100).default([]),
  manual_steps: z.array(z.unknown()).max(100).default([]),
  machine_steps: z.array(z.unknown()).max(100).default([]),
  tag_names_en: z.array(z.string()).max(50).optional().catch([]),
});

export type VerifiedIngredient = z.infer<typeof ingredientSchema>;
export type VerifiedStep = z.infer<typeof stepSchema>;
export type VerifiedRecipe = Omit<z.infer<typeof generatedRecipeSchema>, "ingredients" | "manual_steps" | "machine_steps"> & {
  ingredients: VerifiedIngredient[];
  manual_steps: VerifiedStep[];
  machine_steps: VerifiedStep[];
};

/** The JSON in a model's answer: the text itself, or the first fenced block, or from the first
 *  [ / { to the last ] / }. */
export function extractJson(answer: string): unknown {
  const candidates = [answer.trim()];
  const fenced = /```(?:json)?\s*([\s\S]*?)```/i.exec(answer);
  if (fenced) candidates.push(fenced[1].trim());
  const a = answer.indexOf("["), b = answer.lastIndexOf("]");
  if (a >= 0 && b > a) candidates.push(answer.slice(a, b + 1));
  const c = answer.indexOf("{"), d = answer.lastIndexOf("}");
  if (c >= 0 && d > c) candidates.push(answer.slice(c, d + 1));
  for (const s of candidates) {
    try {
      return JSON.parse(s);
    } catch {
      // the next one
    }
  }
  throw new Error("The model's answer was not valid JSON");
}

/** The recipes of an answer: an array, or an object holding one ({"recipes": [...]}), or one
 *  recipe. Invalid recipes, ingredients and steps are left out. */
export function verifyRecipes(data: unknown): VerifiedRecipe[] {
  let list: unknown[];
  if (Array.isArray(data)) list = data;
  else if (data && typeof data === "object") {
    const arr = Object.values(data).find(Array.isArray);
    list = arr && !("title" in data) ? arr : [data];
  } else throw new Error("The model's answer holds no recipes");
  const out: VerifiedRecipe[] = [];
  for (const raw of list) {
    const r = generatedRecipeSchema.safeParse(raw);
    if (!r.success) continue;
    const steps = (items: unknown[]) =>
      items.flatMap((i) => {
        const p = stepSchema.safeParse(i);
        return p.success ? [p.data] : [];
      });
    out.push({
      ...r.data,
      ingredients: r.data.ingredients.flatMap((i) => {
        const p = ingredientSchema.safeParse(i);
        return p.success ? [p.data] : [];
      }),
      manual_steps: steps(r.data.manual_steps),
      machine_steps: steps(r.data.machine_steps),
    });
  }
  return out;
}
