import { notFound } from "next/navigation";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { db } from "@/lib/db";
import { getRecipe, listIngredients, listUnits } from "@/lib/meals/queries/recipes";
import { CookingView } from "@/components/meals/cooking/cooking-view";

export const dynamic = "force-dynamic";

export default async function CookPage({ params }: { params: Promise<{ familyId: string; id: string }> }) {
  const { familyId, id } = await params;
  await requireFamily(familyId);
  const { locale } = await getI18n();
  const recipe = getRecipe(db, familyId, id);
  if (!recipe) notFound();
  return <CookingView recipe={recipe} ingredients={listIngredients(db)} units={listUnits(db)} locale={locale} />;
}
