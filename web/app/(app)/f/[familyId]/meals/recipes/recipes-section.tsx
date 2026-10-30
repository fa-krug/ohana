import { BookOpen, Plus, Search } from "lucide-react";
import Link from "next/link";
import type { TVars } from "@/lib/i18n/translate";
import { db } from "@/lib/db";
import { listRecipes, listTags } from "@/lib/meals/queries/recipes";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { EmptyState } from "@/components/ui/empty-state";
import { RecipeFilters } from "@/components/meals/recipes/recipe-filters";
import { RecipeList } from "@/components/meals/recipes/recipe-list";

const PAGE = 20;

type RecipesSectionProps = {
  familyId: string;
  canEdit: boolean;
  locale: "en" | "de";
  t: (key: string, vars?: TVars) => string;
  list: string;
  q: string;
  sort: string;
  tagIds: string[];
  deletedId?: string;
  highlightId?: string;
};

/**
 * Async server component holding the recipes' data queries. Rendered inside a
 * <Suspense> boundary so the page shell paints immediately and this list
 * streams in once the queries resolve.
 */
export async function RecipesSection({
  familyId,
  canEdit,
  locale,
  t,
  list,
  q,
  sort,
  tagIds,
  deletedId,
  highlightId,
}: RecipesSectionProps) {
  const allTags = listTags(db, familyId);
  const { items, totalCount } = listRecipes(db, familyId, {
    listType: list,
    search: q,
    tagIds,
    sort,
    locale,
    limit: PAGE,
    offset: 0,
  });

  return (
    <>
      {/* RecipeFilters is a client island — pass only serializable props, NO t function */}
      <Card className="p-3">
        <RecipeFilters list={list} q={q} sort={sort} tags={tagIds} allTags={allTags} locale={locale} />
      </Card>

      {totalCount === 0 ? (
        q ? (
          <EmptyState
            fill
            icon={Search}
            title={t("meals.recipes.noSearchResults")}
            subtitle={t("meals.recipes.noSearchResultsSubtitle")}
          />
        ) : (
          <EmptyState
            fill
            icon={BookOpen}
            title={t("meals.recipes.noRecipesTitle")}
            subtitle={t("meals.recipes.noRecipesSubtitle")}
            action={
              canEdit && (
                <Button asChild>
                  <Link href={`/f/${familyId}/meals/recipes/new?list=${list}`}>
                    <Plus size={16} />
                    {t("meals.recipes.addFirstRecipe")}
                  </Link>
                </Button>
              )
            }
          />
        )
      ) : (
        <RecipeList
          key={`${list}|${q}|${sort}|${tagIds.join(",")}`}
          initialItems={items}
          totalCount={totalCount}
          list={list}
          q={q}
          sort={sort}
          tags={tagIds}
          locale={locale}
          deletedId={deletedId}
          highlightId={highlightId}
        />
      )}
    </>
  );
}
