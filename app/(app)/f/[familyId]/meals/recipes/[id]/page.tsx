import { notFound } from "next/navigation";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { db } from "@/lib/db";
import { getRecipe, listIngredients, listUnits } from "@/lib/meals/queries/recipes";
import { RecipeDetail } from "@/components/meals/recipes/recipe-detail";
import { mealsAi } from "@/lib/meals/ai/status";

export const dynamic = "force-dynamic";

export default async function RecipeDetailPage({ params }: { params: Promise<{ familyId: string; id: string }> }) {
  const { familyId, id } = await params;
  const { role } = await requireFamily(familyId);
  const { locale, t } = await getI18n();

  const recipe = getRecipe(db, familyId, id);
  if (!recipe) notFound();

  const ingredientsById = new Map(listIngredients(db).map((i) => [i.id, i]));
  const unitsById = new Map(listUnits(db).map((u) => [u.id, u]));

  return (
    <RecipeDetail
      recipe={recipe}
      ingredientsById={ingredientsById}
      unitsById={unitsById}
      locale={locale}
      t={t}
      base={`/f/${familyId}/meals`}
      canEdit={role === "editor"}
      canGeneratePhoto={role === "editor" && mealsAi(db, familyId).photos}
    />
  );
}
