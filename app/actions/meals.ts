"use server";

import { revalidatePath } from "next/cache";
import type { Db } from "@/lib/db";
import { run, type Result } from "@/lib/actions/result";
import { AuthError } from "@/lib/auth/errors";
import { requireRole } from "@/lib/families/roles";
import { moveRecipe, deleteRecipe } from "@/lib/meals/recipes/mutations";
import { setupMealPlan } from "@/lib/meals/meal-plan/setup";
import { renewIteration, generateNextIteration } from "@/lib/meals/meal-plan/iterations";
import { setupPlanSchema } from "@/lib/meals/schemas/mutations";
import { upsertRecipe, type UpsertRecipeInput } from "@/lib/meals/recipes/upsert";
import { createTag, updateTag, deleteTag, resetTags } from "@/lib/meals/recipes/tags";
import { setRecipeImage, removeRecipeImage } from "@/lib/meals/recipes/images";
import { ALLOWED_UPLOAD_TYPES, MAX_UPLOAD_BYTES } from "@/lib/meals/images/config";

/** Every meal action changes data: the caller must be an editor of the family. */
function editor<T>(
  familyId: string,
  fn: (ctx: { db: Db; familyId: string; now: Date }) => Promise<T> | T,
): Promise<Result<T>> {
  return run(({ db, user, now }) => {
    requireRole(db, { id: user.id }, familyId, "editor");
    return fn({ db, familyId, now });
  });
}

const base = (familyId: string) => `/f/${familyId}/meals`;

function refreshRecipes(familyId: string, recipeId?: string) {
  revalidatePath(`${base(familyId)}/recipes`);
  if (recipeId) revalidatePath(`${base(familyId)}/recipes/${recipeId}`);
}

function refreshPlan(familyId: string) {
  revalidatePath(`${base(familyId)}/plan`);
  revalidatePath(`${base(familyId)}/shopping`);
  revalidatePath(`/f/${familyId}`);
}

function refreshTags(familyId: string) {
  revalidatePath(`${base(familyId)}/tags`);
  revalidatePath(`${base(familyId)}/recipes`);
}

export async function moveRecipeAction(familyId: string, recipeId: string): Promise<Result<"KNOWN" | "TO_TRY">> {
  const res = await editor(familyId, ({ db, now }) => moveRecipe(db, familyId, recipeId, now));
  if (res.ok) refreshRecipes(familyId, recipeId);
  return res;
}

export async function deleteRecipeAction(familyId: string, recipeId: string): Promise<Result<undefined>> {
  const res = await editor(familyId, ({ db }) => {
    deleteRecipe(db, familyId, recipeId);
    return undefined;
  });
  if (res.ok) refreshRecipes(familyId);
  return res;
}

export async function setupPlanAction(familyId: string, input: unknown): Promise<Result<{ iterationId: string }>> {
  const res = await editor(familyId, ({ db, now }) => setupMealPlan(db, familyId, setupPlanSchema.parse(input), now));
  if (res.ok) refreshPlan(familyId);
  return res;
}

export async function renewIterationAction(familyId: string, iterationId: string): Promise<Result<undefined>> {
  const res = await editor(familyId, ({ db }) => {
    renewIteration(db, familyId, iterationId);
    return undefined;
  });
  if (res.ok) refreshPlan(familyId);
  return res;
}

export async function nextIterationAction(familyId: string): Promise<Result<{ iterationId: string }>> {
  const res = await editor(familyId, ({ db, now }) => generateNextIteration(db, familyId, now));
  if (res.ok) refreshPlan(familyId);
  return res;
}

export async function saveRecipeAction(
  familyId: string,
  recipeId: string | null,
  input: UpsertRecipeInput,
): Promise<Result<{ id: string }>> {
  const res = await editor(familyId, ({ db, now }) => upsertRecipe(db, familyId, recipeId, input, now));
  if (res.ok) refreshRecipes(familyId, res.data.id);
  return res;
}

export async function createTagAction(
  familyId: string,
  input: { category: string; nameEn: string; nameDe: string },
): Promise<Result<{ id: string }>> {
  const res = await editor(familyId, ({ db }) => createTag(db, familyId, input));
  if (res.ok) refreshTags(familyId);
  return res;
}

export async function updateTagAction(
  familyId: string,
  tagId: string,
  input: { nameEn: string; nameDe: string },
): Promise<Result<undefined>> {
  const res = await editor(familyId, ({ db }) => {
    updateTag(db, familyId, tagId, input);
    return undefined;
  });
  if (res.ok) refreshTags(familyId);
  return res;
}

export async function deleteTagAction(familyId: string, tagId: string): Promise<Result<undefined>> {
  const res = await editor(familyId, ({ db }) => {
    deleteTag(db, familyId, tagId);
    return undefined;
  });
  if (res.ok) refreshTags(familyId);
  return res;
}

export async function resetTagsAction(familyId: string): Promise<Result<undefined>> {
  const res = await editor(familyId, ({ db }) => {
    resetTags(db, familyId);
    return undefined;
  });
  if (res.ok) refreshTags(familyId);
  return res;
}

export async function uploadRecipeImageAction(
  familyId: string,
  recipeId: string,
  formData: FormData,
): Promise<Result<undefined>> {
  const res = await editor(familyId, async ({ db, now }) => {
    const file = formData.get("image");
    if (!(file instanceof File)) throw new AuthError(400, "No file provided");
    if (!ALLOWED_UPLOAD_TYPES.has(file.type)) throw new AuthError(400, "Invalid file type");
    if (file.size > MAX_UPLOAD_BYTES) throw new AuthError(400, "File too large (max 5MB)");
    const bytes = Buffer.from(await file.arrayBuffer());
    try {
      await setRecipeImage(db, familyId, recipeId, bytes, now);
    } catch (e) {
      if (e instanceof AuthError) throw e;
      throw new AuthError(400, "Invalid image file");
    }
    return undefined;
  });
  if (res.ok) refreshRecipes(familyId, recipeId);
  return res;
}

export async function removeRecipeImageAction(familyId: string, recipeId: string): Promise<Result<undefined>> {
  const res = await editor(familyId, ({ db }) => {
    removeRecipeImage(db, familyId, recipeId);
    return undefined;
  });
  if (res.ok) refreshRecipes(familyId, recipeId);
  return res;
}
