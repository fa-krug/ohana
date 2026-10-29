import { and, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { recipes } from "@/lib/db/schema";

function ownedRecipe(db: Db, familyId: string, recipeId: string) {
  const row = db
    .select({ id: recipes.id, listType: recipes.listType })
    .from(recipes)
    .where(and(eq(recipes.id, recipeId), eq(recipes.familyId, familyId)))
    .get();
  if (!row) throw new AuthError(404, "Recipe not found");
  return row;
}

export function moveRecipe(
  db: Db,
  familyId: string,
  recipeId: string,
  now: Date,
): "KNOWN" | "TO_TRY" {
  const row = ownedRecipe(db, familyId, recipeId);
  const next = row.listType === "KNOWN" ? "TO_TRY" : "KNOWN";
  db.update(recipes).set({ listType: next, updatedAt: now }).where(eq(recipes.id, recipeId)).run();
  return next;
}

export function deleteRecipe(db: Db, familyId: string, recipeId: string): void {
  ownedRecipe(db, familyId, recipeId);
  db.delete(recipes).where(eq(recipes.id, recipeId)).run();
}
