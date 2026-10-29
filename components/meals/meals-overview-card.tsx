import Link from "next/link";
import { ShoppingCart, UtensilsCrossed } from "lucide-react";
import { db } from "@/lib/db";
import { getMealsSummary } from "@/lib/meals/queries/meal-plan";
import { getI18n } from "@/lib/i18n/server";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

/** The family overview's meals card: today's meal and what's left on the shopping list. */
export async function MealsOverviewCard({ familyId }: { familyId: string }) {
  const { t, locale } = await getI18n();
  const base = `/f/${familyId}/meals`;
  const todayIso = new Date().toISOString().slice(0, 10);
  const { today, shopping } = getMealsSummary(db, familyId, todayIso);
  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="flex items-center gap-2 text-lg">
          <UtensilsCrossed className="size-5 text-primary" /> {t("meals.overview.title")}
        </CardTitle>
      </CardHeader>
      <CardContent className="grid gap-3 sm:grid-cols-2">
        <Link href={today ? `${base}/recipes/${today.recipeId}` : `${base}/plan`} className="rounded-lg border p-3 hover:border-primary">
          <p className="text-xs font-medium uppercase text-muted-foreground">{t("meals.overview.today")}</p>
          <p className="mt-1 truncate font-medium">
            {today ? today.recipeTitle : <span className="text-muted-foreground">{t("meals.overview.nothingPlanned")}</span>}
            {today?.isLeftover && <span className="ml-1.5 text-xs font-normal text-muted-foreground">({t("meals.plan.leftover")})</span>}
          </p>
        </Link>
        <Link href={shopping ? `${base}/shopping/${shopping.id}` : `${base}/shopping`} className="rounded-lg border p-3 hover:border-primary">
          <p className="flex items-center gap-1.5 text-xs font-medium uppercase text-muted-foreground">
            <ShoppingCart className="size-3.5" /> {t("meals.overview.shopping")}
            {shopping?.shoppingDate && (
              <span className="normal-case">
                · {new Date(`${shopping.shoppingDate}T00:00:00`).toLocaleDateString(locale, { weekday: "short", day: "numeric", month: "short" })}
              </span>
            )}
          </p>
          <p className="mt-1 font-medium">
            {!shopping || shopping.total === 0 ? (
              <span className="text-muted-foreground">{t("meals.overview.noList")}</span>
            ) : shopping.open === 0 ? (
              t("meals.overview.allBought")
            ) : (
              t("meals.overview.toBuy", { open: shopping.open, total: shopping.total })
            )}
          </p>
        </Link>
      </CardContent>
    </Card>
  );
}
