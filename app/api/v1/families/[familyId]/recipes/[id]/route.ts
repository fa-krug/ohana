import { db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { handle } from "@/lib/auth/route";
import { getRecipe, listIngredients, listUnits } from "@/lib/meals/queries/recipes";
import { requireFamilyRequest } from "@/lib/meals/route-auth";

export const dynamic = "force-dynamic";

/** One recipe, with the (shared) ingredient and unit lists so a client can show names. */
export async function GET(req: Request, { params }: { params: Promise<{ familyId: string; id: string }> }) {
  return handle(async () => {
    const { familyId, id } = await params;
    await requireFamilyRequest(req, familyId, "viewer");
    const recipe = getRecipe(db, familyId, id);
    if (!recipe) throw new AuthError(404, "Recipe not found");
    return { recipe, ingredients: listIngredients(db), units: listUnits(db) };
  });
}
