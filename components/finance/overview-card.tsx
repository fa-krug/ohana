// The finance part of the family overview: this month's income and expenses (net counting),
// where most of the money went, and what is on the accounts. A server component.

import type { MonthSummary } from "@/lib/finance/summary";
import { formatMoney } from "@/lib/finance/money";
import type { TVars } from "@/lib/i18n/translate";
import { cn } from "@/lib/utils";

export function FinanceOverviewCard({
  summary,
  t,
  locale,
}: {
  summary: MonthSummary;
  t: (key: string, vars?: TVars) => string;
  locale: string;
}) {
  const money = (cents: number, sign = false) => formatMoney(cents, summary.currency, locale, { sign });
  const net = summary.incomeCents - summary.expenseCents;
  const month = new Intl.DateTimeFormat(locale, { month: "long", year: "numeric", timeZone: "UTC" }).format(
    new Date(`${summary.month}-01T00:00:00Z`),
  );
  const top = summary.topExpense;
  return (
    <div className="space-y-3 text-sm">
      <p className="text-xs font-semibold tracking-wide text-muted-foreground uppercase">
        {t("finance.card.thisMonth")} · {month}
      </p>
      {summary.count === 0 ? (
        <p className="text-muted-foreground">{t("finance.card.nothing")}</p>
      ) : (
        <>
          <dl className="grid grid-cols-3 gap-2">
            <div className="min-w-0">
              <dt className="flex items-center gap-1.5 text-xs text-muted-foreground">
                <span className="size-2 shrink-0 rounded-sm bg-(--series-1)" aria-hidden /> {t("finance.card.in")}
              </dt>
              <dd className="truncate font-semibold tabular-nums">{money(summary.incomeCents)}</dd>
            </div>
            <div className="min-w-0">
              <dt className="flex items-center gap-1.5 text-xs text-muted-foreground">
                <span className="size-2 shrink-0 rounded-sm bg-(--series-2)" aria-hidden /> {t("finance.card.out")}
              </dt>
              <dd className="truncate font-semibold tabular-nums">{money(summary.expenseCents)}</dd>
            </div>
            <div className="min-w-0">
              <dt className="text-xs text-muted-foreground">{t("finance.card.net")}</dt>
              <dd className={cn("truncate font-semibold tabular-nums", net < 0 && "text-gap")}>{money(net, true)}</dd>
            </div>
          </dl>
          {top && (
            <p className="flex min-w-0 items-center gap-2">
              <span className="size-3 shrink-0 rounded-full" style={{ backgroundColor: top.color }} aria-hidden />
              <span className="min-w-0 flex-1 truncate">
                {t("finance.card.top", { name: `${top.icon ? `${top.icon} ` : ""}${top.name}` })}
              </span>
              <span className="shrink-0 text-muted-foreground tabular-nums">{money(top.expenseCents)}</span>
            </p>
          )}
        </>
      )}
      {summary.balanceCents !== null && (
        <p className="text-muted-foreground">{t("finance.card.balance", { amount: money(summary.balanceCents) })}</p>
      )}
    </div>
  );
}
