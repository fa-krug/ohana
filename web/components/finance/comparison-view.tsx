"use client";

// The period next to other periods (family-planner's ComparisonView.tsx).

import { formatMoney } from "@/lib/finance/money";
import { useT } from "@/lib/i18n/provider";
import type { TVars } from "@/lib/i18n/translate";
import { cn } from "@/lib/utils";
import type { CategoryTree } from "./category-tree";
import { useFinance } from "./context";
import type { Comparison, ComparisonKey } from "./finance-store";

type T = (key: string, vars?: TVars) => string;

const TITLES: Record<ComparisonKey, string> = {
  month: "finance.compare.month",
  last_month: "finance.compare.lastMonth",
  year: "finance.compare.year",
  last_year: "finance.compare.lastYear",
  all: "finance.compare.all",
};

/** One column's amounts per month; categories by top-level category ("" = uncategorized), with
 *  their subcategories. */
export interface Values {
  incomeCents: number;
  expenseCents: number;
  income: Map<string, number>;
  expense: Map<string, number>;
}

export interface Column {
  key: string;
  title: string;
  detail: string;
  /** Null: nothing to compare yet (no completed month, or no transactions). */
  values: Values | null;
}

/** The top-level category of a category ("" for none, or one that is gone). */
export function topOf(tree: CategoryTree, id: string | null): string {
  let node = id ? tree.byId.get(id) : undefined;
  if (!node) return "";
  for (let p = tree.parentOf(node.category.id); p; p = tree.parentOf(p.id)) {
    node = tree.byId.get(p.id)!;
  }
  return node.category.id;
}

function add(map: Map<string, number>, key: string, cents: number) {
  if (cents) map.set(key, (map.get(key) ?? 0) + cents);
}

function comparisonValues(c: Comparison, tree: CategoryTree): Values | null {
  if (!c.months) return null;
  const v: Values = {
    incomeCents: c.incomeCents,
    expenseCents: c.expenseCents,
    income: new Map(),
    expense: new Map(),
  };
  for (const [id, cents] of c.categories) {
    const top = topOf(tree, id);
    add(v.income, top, cents.incomeCents);
    add(v.expense, top, cents.expenseCents);
  }
  return v;
}

/** A month range in short: "Sep 2026", "Jan – Sep 2026". */
function monthSpan(first: string, last: string, lang: string) {
  const f = new Intl.DateTimeFormat(lang, { month: "short", year: "numeric" });
  const d = (m: string) => new Date(`${m}-01T00:00:00`);
  return first === last ? f.format(d(first)) : f.formatRange(d(first), d(last));
}

export function columnOf(c: Comparison, tree: CategoryTree, lang: string, t: T): Column {
  const values = comparisonValues(c, tree);
  let detail = t("finance.compare.nothingYet");
  if (values && c.first && c.last) {
    detail = c.average
      ? `Ø ${monthSpan(c.first, c.last, lang)} · ${t("finance.compare.months", { count: c.months })}`
      : new Intl.DateTimeFormat(lang, { month: "long", year: "numeric" }).format(new Date(`${c.first}-01T00:00:00`));
  }
  return { key: c.key, title: t(TITLES[c.key]), detail, values };
}

interface Row {
  key: string;
  label: string;
  /** Higher is better (income, the balance) or worse (expenses). */
  good: "higher" | "lower";
  get: (v: Values) => number;
  strong?: boolean;
}

/**
 * The period next to others, all per month: a month with the month before, a year's average
 * completed month with the year before's, all time's average completed month. Below the
 * totals, the top-level categories; the other columns tell how the first one differs from them.
 */
export function ComparisonView() {
  const finance = useFinance();
  const { t, locale: lang } = useT();
  const comparisons = finance.comparisons;
  if (!comparisons) return <div className="h-48 animate-pulse rounded-xl bg-muted" />;
  const tree = finance.categoryTree;
  const currency = finance.currency;
  const columns = comparisons.map((c) => columnOf(c, tree, lang, t));

  const label = (id: string) => {
    const c = tree.byId.get(id)?.category;
    return c ? `${c.icon ? c.icon + " " : ""}${c.name}` : t("finance.uncategorized");
  };
  /** The categories with an amount in any column, largest (in the first column that has
   *  one) first. */
  const categoryRows = (side: "income" | "expense"): Row[] => {
    const keys = new Set(columns.flatMap((c) => (c.values ? [...c.values[side].keys()] : [])));
    const size = (k: string) => columns.map((c) => c.values?.[side].get(k) ?? 0);
    return [...keys]
      .sort((a, b) => {
        const sa = size(a), sb = size(b);
        const i = sa.findIndex((n, j) => n !== sb[j]);
        return i < 0 ? 0 : sb[i] - sa[i];
      })
      .map((k) => ({
        key: `${side}:${k}`,
        label: label(k),
        good: side === "income" ? "higher" : "lower",
        get: (v) => v[side].get(k) ?? 0,
      }));
  };
  const net = (v: Values) => v.incomeCents - v.expenseCents;
  const totals: Row[] = [
    { key: "income", label: t("finance.income"), good: "higher", get: (v) => v.incomeCents },
    { key: "expense", label: t("finance.expenses"), good: "lower", get: (v) => v.expenseCents },
    { key: "net", label: t("finance.net"), good: "higher", get: net, strong: true },
  ];
  const groups: { title?: string; rows: Row[] }[] = [
    { rows: totals },
    { title: t("finance.compare.expensesByCategory"), rows: categoryRows("expense") },
    { title: t("finance.compare.incomeByCategory"), rows: categoryRows("income") },
  ].filter((g) => g.rows.length);

  // Averages per month in whole units: cents would only crowd the columns.
  const money = (cents: number, sign = false) =>
    formatMoney(cents, currency, lang, { sign, whole: true });
  const current = columns[0].values;

  /** How the first column differs from this one, in percent of this one. */
  const delta = (row: Row, value: number | null) => {
    const base = current ? row.get(current) : null;
    if (base === null || value === null || !value || base === value) return null;
    const pct = Math.round(((base - value) / Math.abs(value)) * 100);
    if (!pct) return null;
    const better = row.good === "higher" ? base > value : base < value;
    return (
      <div
        className={cn("text-[11px] font-normal", better ? "text-ok" : "text-gap")}
        title={t("finance.compare.deltaTitle", {
          first: columns[0].title,
          diff: money(base - value, true),
        })}
      >
        {pct > 0 ? `+${pct} %` : `−${-pct} %`}
      </div>
    );
  };

  return (
    <section className="rounded-xl border bg-card p-4">
      <div className="mb-3 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <h2 className="font-semibold">{t("finance.compare.title")}</h2>
        <span className="text-xs text-muted-foreground">{t("finance.compare.perMonth")}</span>
      </div>
      <div className="-mx-4 overflow-x-auto px-4">
        <table className="w-full text-xs sm:text-sm">
          <thead>
            <tr className="align-bottom">
              <th className="sr-only">{t("finance.compare.title")}</th>
              {columns.map((c, i) => (
                <th
                  key={c.key}
                  className={cn(
                    "pb-2 pl-2 text-right font-medium sm:pl-3",
                    i === 0 && "text-foreground",
                    i > 0 && "text-muted-foreground",
                  )}
                >
                  <div>{c.title}</div>
                  <div
                    className="ml-auto max-w-44 text-[11px] font-normal text-muted-foreground sm:truncate"
                    title={c.detail}
                  >
                    {c.detail}
                  </div>
                </th>
              ))}
            </tr>
          </thead>
          {groups.map((g, gi) => (
            <tbody key={g.title ?? gi} className="border-t tabular-nums">
              {g.title && (
                <tr>
                  <th
                    colSpan={columns.length + 1}
                    className="pt-3 pb-1 text-left text-xs font-medium text-muted-foreground"
                  >
                    {g.title}
                  </th>
                </tr>
              )}
              {g.rows.map((row) => (
                <tr key={row.key} className="align-top">
                  <th
                    scope="row"
                    className={cn(
                      "max-w-28 truncate py-1.5 pr-1 text-left font-normal sm:max-w-40 sm:pr-2",
                      row.strong && "font-semibold",
                    )}
                    title={row.label}
                  >
                    {row.label}
                  </th>
                  {columns.map((c, i) => {
                    const value = c.values ? row.get(c.values) : null;
                    return (
                      <td
                        key={c.key}
                        className={cn(
                          "py-1.5 pl-2 text-right whitespace-nowrap sm:pl-3",
                          row.strong && "font-semibold",
                          i === 0 && "font-medium",
                          i > 0 && !row.strong && "text-muted-foreground",
                          row.key === "net" && value !== null && value < 0 && "text-gap",
                        )}
                      >
                        {value === null
                          ? <span className="text-muted-foreground">—</span>
                          : money(value, row.key === "net")}
                        {i > 0 && delta(row, value)}
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          ))}
        </table>
      </div>
      {columns.length > 1 && current && (
        <p className="mt-2 text-xs text-muted-foreground">
          {t("finance.compare.deltaHint", { first: columns[0].title })}
        </p>
      )}
    </section>
  );
}
