import { notFound, redirect } from "next/navigation";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { db } from "@/lib/db";
import { listTags } from "@/lib/meals/queries/recipes";
import { mealsAi } from "@/lib/meals/ai/status";
import { GenerateRecipes } from "@/components/meals/recipes/generate-recipes";

export const dynamic = "force-dynamic";

/** cookless's recipe generator: editors, with the family's AI set up (else to Settings → AI). */
export default async function GenerateRecipesPage({ params }: { params: Promise<{ familyId: string }> }) {
  const { familyId } = await params;
  const { role } = await requireFamily(familyId);
  if (role !== "editor") notFound();
  const ai = mealsAi(db, familyId);
  if (!ai.generate) redirect(`/f/${familyId}/settings?tab=ai`);
  const { locale } = await getI18n();
  return <GenerateRecipes tags={listTags(db, familyId)} locale={locale} photos={ai.photos} />;
}
