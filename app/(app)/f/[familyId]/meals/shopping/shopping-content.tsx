import type { Locale } from "@/lib/i18n/config";
import { db } from "@/lib/db";
import { getLatestShoppingList } from "@/lib/meals/queries/shopping";
import { ShoppingListView } from "@/components/meals/shopping/shopping-list-view";
import { ShoppingSpentCard } from "@/components/meals/shopping/spent-card";

/**
 * Async server component holding the shopping-list data query. Rendered inside
 * a <Suspense> boundary so the page shows its skeleton immediately and the
 * list streams in once the query resolves.
 */
export async function ShoppingContent({
  familyId,
  canEdit,
  locale,
}: {
  familyId: string;
  canEdit: boolean;
  locale: Locale;
}) {
  const list = getLatestShoppingList(db, familyId, locale);
  if (!list?.shoppingDate) return <ShoppingListView list={list} familyId={familyId} canEdit={canEdit} />;
  return (
    <div className="space-y-4">
      <ShoppingListView list={list} familyId={familyId} canEdit={canEdit} />
      <ShoppingSpentCard familyId={familyId} shoppingDate={list.shoppingDate} />
    </div>
  );
}
