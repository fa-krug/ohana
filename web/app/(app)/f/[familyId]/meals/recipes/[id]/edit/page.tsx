import { notFound } from "next/navigation";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { db } from "@/lib/db";
import { getRecipe, listIngredients, listUnits, listTags } from "@/lib/meals/queries/recipes";
import { RecipeEditor } from "@/components/meals/recipes/recipe-editor";
import { toInitialValues } from "@/components/meals/recipes/editor/to-initial-values";

export const dynamic = "force-dynamic";

export default async function EditRecipePage({ params }: { params: Promise<{ familyId: string; id: string }> }) {
  const { familyId, id } = await params;
  const { role } = await requireFamily(familyId);
  if (role !== "editor") notFound();
  const { locale } = await getI18n();

  const recipe = getRecipe(db, familyId, id);
  if (!recipe) notFound();

  return (
    <RecipeEditor
      mode="edit"
      recipeId={recipe.id}
      listType={recipe.listType as "KNOWN" | "TO_TRY"}
      initialValues={toInitialValues(recipe)}
      ingredients={listIngredients(db)}
      units={listUnits(db)}
      tags={listTags(db, familyId)}
      locale={locale}
    />
  );
}
