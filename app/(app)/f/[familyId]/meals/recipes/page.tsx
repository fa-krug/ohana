import { Suspense } from "react";
import { Plus } from "lucide-react";
import Link from "next/link";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { RecipeListSkeleton } from "@/components/meals/recipes/recipe-list-skeleton";
import { RecipesSection } from "./recipes-section";

export const dynamic = "force-dynamic";

export default async function RecipesPage({
  params,
  searchParams,
}: {
  params: Promise<{ familyId: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const { familyId } = await params;
  const sp = await searchParams;
  const { role } = await requireFamily(familyId);
  const { locale, t } = await getI18n();
  const base = `/f/${familyId}/meals`;

  const list = typeof sp.list === "string" ? sp.list : "KNOWN";
  const q = typeof sp.q === "string" ? sp.q : "";
  const sort = typeof sp.sort === "string" ? sp.sort : "name-asc";
  const tagIds = typeof sp.tags === "string" && sp.tags ? sp.tags.split(",") : [];
  const deletedId = typeof sp.deleted === "string" ? sp.deleted : undefined;
  const highlightId = typeof sp.new === "string" ? sp.new : undefined;
  const canEdit = role === "editor";

  return (
    <div className="flex flex-1 flex-col gap-4">
      <div className="flex items-center justify-between gap-2">
        <h1 className="text-2xl font-bold">{t("meals.recipes.title")}</h1>
        {canEdit && (
          <Button asChild size="sm">
            <Link href={`${base}/recipes/new?list=${list}`}>
              <Plus size={16} />
              {t("meals.recipes.addRecipe")}
            </Link>
          </Button>
        )}
      </div>

      <Suspense
        key={`${list}|${q}|${sort}|${tagIds.join(",")}`}
        fallback={
          <>
            <Skeleton className="h-12 w-full rounded-xl" />
            <RecipeListSkeleton />
          </>
        }
      >
        <RecipesSection
          familyId={familyId}
          canEdit={canEdit}
          locale={locale}
          t={t}
          list={list}
          q={q}
          sort={sort}
          tagIds={tagIds}
          deletedId={deletedId}
          highlightId={highlightId}
        />
      </Suspense>
    </div>
  );
}
