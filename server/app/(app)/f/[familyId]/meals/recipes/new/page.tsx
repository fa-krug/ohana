import { notFound } from "next/navigation";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { db } from "@/lib/db";
import { listIngredients, listUnits, listTags } from "@/lib/meals/queries/recipes";
import { RecipeEditor } from "@/components/meals/recipes/recipe-editor";

export const dynamic = "force-dynamic";

export default async function NewRecipePage({
  params,
  searchParams,
}: {
  params: Promise<{ familyId: string }>;
  searchParams: Promise<{ list?: string }>;
}) {
  const { familyId } = await params;
  const { list } = await searchParams;
  const { role } = await requireFamily(familyId);
  if (role !== "editor") notFound();
  const { locale } = await getI18n();
  const listType = list === "KNOWN" ? "KNOWN" : "TO_TRY";

  return (
    <RecipeEditor
      mode="create"
      recipeId={null}
      listType={listType}
      ingredients={listIngredients(db)}
      units={listUnits(db)}
      tags={listTags(db, familyId)}
      locale={locale}
    />
  );
}
