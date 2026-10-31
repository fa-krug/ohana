"use client";

// The finance page: period, account balances, transactions and the overview (summary,
// comparison, statistic average). Ported from family-planner's FinancePage.tsx.

import { useEffect, useState } from "react";
import { ChevronLeft, ChevronRight, Plus, Upload } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { formatMoney } from "@/lib/finance/money";
import { useT } from "@/lib/i18n/provider";
import { cn } from "@/lib/utils";
import type { Transaction } from "./api";
import { FinanceProvider, useFinance } from "./context";
import { type PeriodMode, today } from "./finance-store";
import { ImportDialog } from "./import-dialog";
import { SummaryView } from "./summary-view";
import { TransactionDialog } from "./transaction-dialog";
import { TransactionsView } from "./transactions-view";
import { ShoppingLinksProvider } from "./shopping-links";
import type { ShoppingLinks } from "@/lib/finance/groceries-links";

/** True once mounted: the page works with the browser's date and time zone. */
function useMounted() {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  return mounted;
}

export function FinancePage({
  familyId,
  readOnly,
  shoppingLinks = { categoryIds: [], lists: [] },
}: {
  familyId: string;
  readOnly: boolean;
  /** Groceries transactions link to the shopping list of their day (phase 7). */
  shoppingLinks?: ShoppingLinks;
}) {
  const mounted = useMounted();
  const { t } = useT();
  if (!mounted) {
    return (
      <div className="space-y-3" aria-busy="true">
        <h1 className="text-2xl font-semibold tracking-tight">{t("nav.finance")}</h1>
        <Skeleton className="h-9 w-full max-w-md" />
        <Skeleton className="h-[50vh] w-full" />
      </div>
    );
  }
  return (
    <FinanceProvider familyId={familyId} readOnly={readOnly}>
      <ShoppingLinksProvider familyId={familyId} links={shoppingLinks}>
        <Finance />
      </ShoppingLinksProvider>
    </FinanceProvider>
  );
}

function Finance() {
  const finance = useFinance();
  const { t } = useT();
  const [editing, setEditing] = useState<Transaction | "new" | null>(null);
  const [importing, setImporting] = useState(false);
  const [tab, setTab] = useState("transactions");

  useEffect(() => finance.open(), [finance]);

  useEffect(() => {
    if (tab === "overview") void finance.loadSummary();
  }, [tab, finance]);

  const edit = !finance.readOnly;
  const list = finance.list;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <h1 className="mr-2 text-2xl font-semibold tracking-tight">{t("nav.finance")}</h1>
        {/* Phones have no room for it next to the buttons: it gets its own row below. */}
        <PeriodNav className="max-sm:hidden" />
        <div className="flex-1" />
        {edit && (
          <>
            <Button size="sm" variant="outline" onClick={() => setImporting(true)}>
              <Upload /> <span className="max-md:sr-only">{t("finance.importCsv")}</span>
            </Button>
            <Button size="sm" onClick={() => setEditing("new")}>
              <Plus /> <span className="max-md:sr-only">{t("finance.add")}</span>
            </Button>
          </>
        )}
      </div>
      <PeriodNav className="justify-between sm:hidden" />
      <Tabs value={tab} onValueChange={setTab}>
        <TabsList>
          <TabsTrigger value="transactions">{t("finance.transactions")}</TabsTrigger>
          <TabsTrigger value="overview">{t("finance.overview")}</TabsTrigger>
        </TabsList>
        <TabsContent value="transactions" className="mt-4 space-y-4">
          {finance.accounts.length > 0 && <AccountCards />}
          {list && <StatTiles income={list.incomeCents} expense={list.expenseCents} currency={finance.currency} />}
          <TransactionsView onEdit={edit ? setEditing : undefined} />
        </TabsContent>
        <TabsContent value="overview" className="mt-4">
          <SummaryView />
        </TabsContent>
      </Tabs>
      {editing && <TransactionDialog transaction={editing === "new" ? null : editing} onClose={() => setEditing(null)} />}
      {importing && <ImportDialog onClose={() => setImporting(false)} />}
    </div>
  );
}

// Account cards and stat tiles share one grid and one tile shape, so the two rows line up.
const tileGrid = "grid grid-cols-3 gap-2 sm:gap-3";
const tileBox = "min-w-0 rounded-xl border bg-card px-2 py-2.5 text-left sm:px-4 sm:py-3";
const tileValue = "mt-0.5 truncate text-[13px] font-semibold tabular-nums sm:text-xl";

/** Income, expenses and the difference, as headline numbers. */
export function StatTiles({ income, expense, currency }: { income: number; expense: number; currency: string }) {
  const { t, locale } = useT();
  const net = income - expense;
  const tiles = [
    { label: t("finance.income"), dot: "bg-(--series-1)", value: formatMoney(income, currency, locale) },
    { label: t("finance.expenses"), dot: "bg-(--series-2)", value: formatMoney(expense, currency, locale) },
    {
      label: t("finance.net"),
      value: formatMoney(net, currency, locale, { sign: true }),
      negative: net < 0,
      hint: income > 0 ? t("finance.savingsRate", { n: Math.round((net / income) * 100) }) : "",
    },
  ];
  return (
    <div className={tileGrid}>
      {tiles.map((tile) => (
        <div key={tile.label} className={tileBox}>
          <div className="flex min-w-0 items-center gap-1.5 text-xs text-muted-foreground">
            {tile.dot && <span className={cn("size-2.5 shrink-0 rounded-sm", tile.dot)} />}
            <span className="truncate">{tile.label}</span>
            {tile.hint && <span className="ml-auto shrink-0 max-sm:hidden">{tile.hint}</span>}
          </div>
          <div className={cn(tileValue, tile.negative && "text-gap")}>{tile.value}</div>
          {tile.hint && <div className="truncate text-xs text-muted-foreground sm:hidden">{tile.hint}</div>}
        </div>
      ))}
    </div>
  );
}

/** The accounts with their balances on the day the period shows (its last day, or today while
 *  it runs); picking one shows only its transactions. With several accounts a total comes
 *  first, and picking it shows them all again. On another day than today, the cards also tell
 *  the balances now. */
function AccountCards() {
  const finance = useFinance();
  const { t, locale } = useT();
  const active = finance.filter.account;
  const at = finance.balances?.at;
  const day = at
    ? new Intl.DateTimeFormat(locale, { day: "numeric", month: "short", year: "numeric" }).format(
        new Date(at + "T00:00:00"),
      )
    : "";
  const past = !!at && at !== today();
  const cards = finance.accounts.map((a) => ({
    id: a.id,
    label: `${a.icon ? `${a.icon} ` : ""}${a.name}`,
    color: a.color as string | undefined,
    cents: finance.balanceOf(a),
    now: a.balanceCents,
  }));
  if (cards.length > 1) {
    cards.unshift({
      id: "",
      label: t("finance.allAccounts"),
      color: undefined,
      cents: cards.reduce((sum, c) => sum + c.cents, 0),
      now: cards.reduce((sum, c) => sum + c.now, 0),
    });
  }
  return (
    <div className="space-y-1.5">
      {past && (
        <p className="text-xs text-muted-foreground">
          {t("finance.balanceOn", { date: day })}
          {cards.some((c) => c.now !== c.cents) && <span className="sm:hidden">{` ${t("finance.balanceNowBelow")}`}</span>}
        </p>
      )}
      <div className={tileGrid}>
        {cards.map((c) => (
          <button
            key={c.id || "all"}
            type="button"
            aria-pressed={active === c.id}
            title={day ? t("finance.balanceOn", { date: day }) : t("finance.balance")}
            className={cn(
              tileBox,
              "transition-colors hover:bg-accent",
              c.id && active === c.id && "border-primary ring-1 ring-primary",
            )}
            onClick={() => finance.setFilter({ account: active === c.id ? "" : c.id })}
          >
            <div className="flex min-w-0 items-center gap-1.5 text-xs text-muted-foreground">
              {c.color && <span className="size-2.5 shrink-0 rounded-full" style={{ backgroundColor: c.color }} />}
              <span className="truncate">{c.label}</span>
            </div>
            <div className={cn(tileValue, c.cents < 0 && "text-gap")}>{formatMoney(c.cents, finance.currency, locale)}</div>
            {past && c.now !== c.cents && (
              <div className="truncate text-xs text-muted-foreground tabular-nums">
                <span className="max-sm:hidden">{`${t("finance.balanceNow")} `}</span>
                {formatMoney(c.now, finance.currency, locale)}
              </div>
            )}
          </button>
        ))}
      </div>
    </div>
  );
}

function PeriodNav({ className }: { className?: string }) {
  const finance = useFinance();
  const { t, locale } = useT();
  const { mode, year } = finance.period;
  const monthLabel = (month: "long" | "short") =>
    new Intl.DateTimeFormat(locale, { month, year: "numeric" }).format(new Date(year, finance.period.month, 1));
  const label =
    mode === "all" ? (
      t("finance.allTime")
    ) : mode === "year" ? (
      String(year)
    ) : (
      <>
        <span className="max-sm:hidden">{monthLabel("long")}</span>
        <span className="sm:hidden">{monthLabel("short")}</span>
      </>
    );
  return (
    <div className={cn("flex min-w-0 items-center gap-1", className)}>
      <Select value={mode} onValueChange={(v) => finance.setPeriod({ mode: v as PeriodMode })}>
        <SelectTrigger className="h-8 w-auto gap-1.5" aria-label={t("finance.period")}>
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="month">{t("finance.month")}</SelectItem>
          <SelectItem value="year">{t("finance.year")}</SelectItem>
          <SelectItem value="all">{t("finance.allTime")}</SelectItem>
        </SelectContent>
      </Select>
      {mode !== "all" && (
        <div className="flex min-w-0 items-center gap-1">
          <Button variant="ghost" size="icon" aria-label={t("finance.previous")} onClick={() => finance.step(-1)}>
            <ChevronLeft />
          </Button>
          <span
            className={cn(
              "truncate text-center text-sm font-semibold tabular-nums",
              mode === "month" ? "min-w-16 sm:min-w-28" : "min-w-12",
            )}
          >
            {label}
          </span>
          <Button variant="ghost" size="icon" aria-label={t("finance.next")} onClick={() => finance.step(1)}>
            <ChevronRight />
          </Button>
        </div>
      )}
    </div>
  );
}
