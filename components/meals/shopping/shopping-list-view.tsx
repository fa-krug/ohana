import { CheckCircle, ShoppingCart } from "lucide-react";
import Link from "next/link";
import { getI18n } from "@/lib/i18n/server";
import type { ShoppingListView as ShoppingListDto, ShoppingItemDto } from "@/lib/meals/queries/shopping";
import { EmptyState } from "@/components/ui/empty-state";
import { ShoppingCategory } from "@/components/meals/shopping/shopping-category";
import { UncheckAllButton } from "@/components/meals/shopping/shopping-actions";
import { CATEGORY_ORDER } from "@/lib/meals/display/format";

export async function ShoppingListView({
  list,
  showDate = false,
  familyId,
  canEdit,
}: {
  list: ShoppingListDto | null;
  showDate?: boolean;
  familyId: string;
  canEdit: boolean;
}) {
  const { locale, t } = await getI18n();

  const title = <h1 className="text-2xl font-bold">{t("meals.shopping.title")}</h1>;

  if (!list || list.items.length === 0) {
    return (
      <div className="flex flex-1 flex-col gap-4">
        {title}
        <EmptyState
          fill
          icon={ShoppingCart}
          title={t("meals.shopping.emptyTitle")}
          subtitle={t("meals.shopping.emptySubtitle")}
          action={
            <Link href={`/f/${familyId}/meals/plan`} className="text-sm font-medium text-primary hover:underline">
              {t("meals.shopping.goToPlan")}
            </Link>
          }
        />
      </div>
    );
  }

  if (list.items.every((i) => i.isChecked)) {
    return (
      <div className="flex flex-1 flex-col gap-4">
        {title}
        <EmptyState
          fill
          icon={CheckCircle}
          title={t("meals.shopping.allDoneTitle")}
          subtitle={t("meals.shopping.allDoneSubtitle")}
          action={
            <Link href={`/f/${familyId}/meals/plan`} className="text-sm font-medium text-primary hover:underline">
              {t("meals.shopping.backToPlan")}
            </Link>
          }
        />
      </div>
    );
  }

  const dateLabel =
    showDate && list.shoppingDate
      ? t("meals.shopping.forDate", {
          date: new Date(list.shoppingDate + "T00:00:00").toLocaleDateString(locale, {
            month: "short",
            day: "numeric",
          }),
        })
      : t("meals.shopping.linkedToPlan");

  const byCategory = new Map<string, ShoppingItemDto[]>();
  for (const item of list.items) {
    const cat = (CATEGORY_ORDER as readonly string[]).includes(item.category) ? item.category : "OTHER";
    const arr = byCategory.get(cat) ?? [];
    arr.push(item);
    byCategory.set(cat, arr);
  }

  return (
    <div className="space-y-4">
      {title}
      <div className="flex items-center justify-between">
        <p className="text-sm text-muted-foreground">{dateLabel}</p>
        {canEdit && <UncheckAllButton itemIds={list.items.filter((i) => i.isChecked).map((i) => i.id)} />}
      </div>
      <div className="space-y-3">
        {CATEGORY_ORDER.filter((c) => byCategory.has(c)).map((c) => (
          <ShoppingCategory key={c} category={c} items={byCategory.get(c)!} />
        ))}
      </div>
    </div>
  );
}
