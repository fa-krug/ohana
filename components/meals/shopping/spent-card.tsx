// Meals → Finance (phase 7): what the shopping trip of a list cost, read from the finances:
// the groceries transactions on its shopping day ± 1 day. Read-only; a server component.

import Link from "next/link";
import { Wallet } from "lucide-react";
import { db } from "@/lib/db";
import { getI18n } from "@/lib/i18n/server";
import { formatMoney } from "@/lib/finance/money";
import { shoppingSpend } from "@/lib/finance/groceries";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

export async function ShoppingSpentCard({ familyId, shoppingDate }: { familyId: string; shoppingDate: string }) {
  const { t, locale } = await getI18n();
  const spend = await shoppingSpend(db, familyId, shoppingDate);
  const money = (c: number) => formatMoney(c, spend.currency, locale);
  const day = (d: string) =>
    new Intl.DateTimeFormat(locale, { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" }).format(
      new Date(`${d}T00:00:00Z`),
    );
  const financeHref = `/f/${familyId}/finance`;
  return (
    <Card>
      <CardHeader className="p-4 pb-2">
        <CardTitle className="flex items-center gap-2 text-base">
          <Wallet className="size-4 text-primary" /> {t("meals.spent.title")}
          {spend.transactions.length > 0 && (
            <span className="ml-auto font-semibold tabular-nums">{money(spend.totalCents)}</span>
          )}
        </CardTitle>
        <CardDescription>
          {spend.category
            ? t("meals.spent.hint", {
                category: `${spend.category.icon ? `${spend.category.icon} ` : ""}${spend.category.name}`,
                from: day(spend.from),
                to: day(spend.to),
              })
            : t("meals.spent.noCategory")}
        </CardDescription>
      </CardHeader>
      <CardContent className="p-4 pt-0 text-sm">
        {!spend.category ? (
          <Link href={`/f/${familyId}/settings?tab=finance`} className="font-medium text-primary hover:underline">
            {t("meals.spent.setCategory")}
          </Link>
        ) : spend.transactions.length === 0 ? (
          <p className="text-muted-foreground">{t("meals.spent.none")}</p>
        ) : (
          <ul className="divide-y">
            {spend.transactions.map((tx) => (
              <li key={tx.id} className="flex items-center gap-3 py-1.5">
                <span className="w-24 shrink-0 text-muted-foreground tabular-nums">{day(tx.date)}</span>
                <span className="min-w-0 flex-1 truncate">{tx.payee || tx.description || "—"}</span>
                <span className="shrink-0 tabular-nums">{money(tx.amountCents)}</span>
              </li>
            ))}
          </ul>
        )}
        {spend.category && (
          <Link href={financeHref} className="mt-2 inline-block text-xs font-medium text-primary hover:underline">
            {t("meals.spent.openFinance")}
          </Link>
        )}
      </CardContent>
    </Card>
  );
}
