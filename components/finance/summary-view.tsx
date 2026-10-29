"use client";

// The finance overview (family-planner's SummaryView.tsx): headline numbers, the comparison,
// the statistic average, income and expenses per month, and where the money went.

import { useState } from "react";
import { ChevronRight } from "lucide-react";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { formatMoney } from "@/lib/finance/money";
import { useT } from "@/lib/i18n/provider";
import { cn } from "@/lib/utils";
import type { Category, FinanceSummary } from "./api";
import { BenchmarkView } from "./benchmark-view";
import type { CategoryNode } from "./category-tree";
import { ComparisonView } from "./comparison-view";
import { useFinance } from "./context";
import { StatTiles } from "./finance-page";

/** Income and expenses per month, how they compare with other periods and the statistic
 *  average, and where the money went, for the chosen period (a single month has no chart per
 *  month). */
export function SummaryView() {
  const finance = useFinance();
  const { t } = useT();
  const summary = finance.summary;
  if (!summary) {
    return <div className="h-64 animate-pulse rounded-xl bg-muted" />;
  }
  if (!summary.count) {
    // Nothing in the period, but maybe in those it is compared with.
    return (
      <div className="space-y-4">
        <p className="rounded-xl border bg-card p-8 text-center text-sm text-muted-foreground">
          {t("finance.noData")}
        </p>
        <ComparisonView />
        <BenchmarkView />
      </div>
    );
  }
  return (
    <div className="space-y-4">
      <StatTiles
        income={summary.incomeCents}
        expense={summary.expenseCents}
        currency={summary.currency}
      />
      <ComparisonView />
      <BenchmarkView />
      {finance.period.mode !== "month" && <MonthlyChart summary={summary} />}
      <CategoryBreakdown summary={summary} />
    </div>
  );
}

/** Every month of the range: a whole year, or all months with transactions. */
function monthsOf(summary: FinanceSummary, year: number | null) {
  if (year === null) return summary.months;
  const byMonth = new Map(summary.months.map((m) => [m.month, m]));
  return Array.from({ length: 12 }, (_, i) => {
    const month = `${year}-${String(i + 1).padStart(2, "0")}`;
    return byMonth.get(month) ?? { month, incomeCents: 0, expenseCents: 0 };
  });
}

/** A round axis maximum and its ticks (1, 2, 2.5 or 5 × 10^n steps). */
function niceTicks(max: number, count = 4) {
  if (max <= 0) return { top: 1, ticks: [0] };
  const raw = max / count;
  const pow = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((f) => f * pow).find((s) => s >= raw)!;
  const top = Math.ceil(max / step) * step;
  return {
    top,
    ticks: Array.from(
      { length: Math.round(top / step) + 1 },
      (_, i) => i * step,
    ),
  };
}

/** A bar with 4px rounded ends away from the baseline. */
function barPath(x: number, y: number, w: number, h: number) {
  if (h <= 0) return "";
  const r = Math.min(4, w / 2, h);
  return `M${x},${y + h}V${y + r}Q${x},${y} ${x + r},${y}H${x + w - r}Q${x + w},${y} ${x + w},${
    y + r
  }V${y + h}Z`;
}

function MonthlyChart({ summary }: { summary: FinanceSummary }) {
  const finance = useFinance();
  const { t, locale: lang } = useT();
  const [hover, setHover] = useState<number | null>(null);
  const year = finance.period.mode === "all" ? null : finance.period.year;
  const months = monthsOf(summary, year);
  const money = (c: number, compact = false) => formatMoney(c, summary.currency, lang, { compact });
  const monthName = (m: string, style: "short" | "long" = "short") =>
    new Intl.DateTimeFormat(lang, {
      month: style,
      ...(year === null || style === "long" ? { year: "numeric" } : {}),
    })
      .format(new Date(`${m}-01T00:00:00`));

  const { top, ticks } = niceTicks(
    Math.max(...months.map((m) => Math.max(m.incomeCents, m.expenseCents))),
  );
  const W = 720, H = 240, left = 64, right = 8, topPad = 8, bottom = 28;
  const plotW = W - left - right, plotH = H - topPad - bottom;
  const band = plotW / months.length;
  const barW = Math.max(3, Math.min(18, (band - 10) / 2));
  const y = (v: number) => topPad + plotH - (v / top) * plotH;
  const labelEvery = Math.ceil(months.length / 12);
  const hovered = hover !== null ? months[hover] : null;

  return (
    <section className="rounded-xl border bg-card p-4">
      <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
        <h2 className="font-semibold">{t("finance.perMonth")}</h2>
        <div className="flex gap-4 text-xs text-muted-foreground" aria-hidden>
          <span className="inline-flex items-center gap-1.5">
            <span className="size-2.5 rounded-sm bg-(--series-1)" /> {t("finance.income")}
          </span>
          <span className="inline-flex items-center gap-1.5">
            <span className="size-2.5 rounded-sm bg-(--series-2)" /> {t("finance.expenses")}
          </span>
        </div>
      </div>
      <div className="relative">
        <svg
          viewBox={`0 0 ${W} ${H}`}
          className="h-auto w-full overflow-visible"
          role="img"
          aria-label={t("finance.perMonth")}
          onPointerLeave={() => setHover(null)}
        >
          {ticks.map((v) => (
            <g key={v}>
              <line
                x1={left}
                x2={W - right}
                y1={y(v)}
                y2={y(v)}
                className="stroke-border"
                strokeWidth={v ? 1 : 1.5}
              />
              <text
                x={left - 8}
                y={y(v)}
                dy="0.32em"
                textAnchor="end"
                className="fill-muted-foreground text-[11px] tabular-nums"
              >
                {money(v, true)}
              </text>
            </g>
          ))}
          {months.map((m, i) => {
            const cx = left + band * i + band / 2;
            return (
              <g key={m.month}>
                {hover === i && (
                  <rect
                    x={left + band * i}
                    y={topPad}
                    width={band}
                    height={plotH}
                    className="fill-muted"
                  />
                )}
                {/* 2px surface gap between the two bars of a month */}
                <path
                  d={barPath(
                    cx - barW - 1,
                    y(m.incomeCents),
                    barW,
                    y(0) - y(m.incomeCents),
                  )}
                  fill="var(--series-1)"
                />
                <path
                  d={barPath(
                    cx + 1,
                    y(m.expenseCents),
                    barW,
                    y(0) - y(m.expenseCents),
                  )}
                  fill="var(--series-2)"
                />
                {i % labelEvery === 0 && (
                  <text
                    x={cx}
                    y={H - 8}
                    textAnchor="middle"
                    className="fill-muted-foreground text-[11px]"
                  >
                    {monthName(m.month)}
                  </text>
                )}
                {/* the hit target is the whole month, bigger than its bars */}
                <rect
                  x={left + band * i}
                  y={topPad}
                  width={band}
                  height={plotH + bottom}
                  fill="transparent"
                  onPointerEnter={() => setHover(i)}
                  onPointerDown={() => setHover(i)}
                >
                  <title>
                    {`${monthName(m.month, "long")}: +${money(m.incomeCents)} / −${
                      money(m.expenseCents)
                    }`}
                  </title>
                </rect>
              </g>
            );
          })}
        </svg>
        {hovered && (
          <div
            className="pointer-events-none absolute top-2 z-10 min-w-44 rounded-lg border bg-popover px-3 py-2 text-xs shadow-md"
            style={{
              left: `${((left + band * hover! + band / 2) / W) * 100}%`,
              transform: hover! > months.length / 2
                ? "translateX(calc(-100% - 12px))"
                : "translateX(12px)",
            }}
          >
            <div className="mb-1 font-semibold">
              {monthName(hovered.month, "long")}
            </div>
            <Row
              color="var(--series-1)"
              label={t("finance.income")}
              value={money(hovered.incomeCents)}
            />
            <Row
              color="var(--series-2)"
              label={t("finance.expenses")}
              value={money(hovered.expenseCents)}
            />
            <div className="mt-1 flex justify-between gap-4 border-t pt-1">
              <span className="text-muted-foreground">{t("finance.net")}</span>
              <span className="font-medium tabular-nums">
                {formatMoney(
                  hovered.incomeCents - hovered.expenseCents,
                  summary.currency,
                  lang,
                  {
                    sign: true,
                  },
                )}
              </span>
            </div>
          </div>
        )}
      </div>
      <details className="mt-2 text-sm">
        <summary className="cursor-pointer text-xs font-medium text-muted-foreground">
          {t("finance.asTable")}
        </summary>
        <table className="mt-2 w-full text-sm">
          <thead className="text-left text-xs text-muted-foreground">
            <tr>
              <th className="py-1 font-medium">{t("finance.month")}</th>
              <th className="py-1 text-right font-medium">
                {t("finance.income")}
              </th>
              <th className="py-1 text-right font-medium">
                {t("finance.expenses")}
              </th>
              <th className="py-1 text-right font-medium">
                {t("finance.net")}
              </th>
            </tr>
          </thead>
          <tbody className="divide-y tabular-nums">
            {months.map((m) => (
              <tr key={m.month}>
                <td className="py-1">{monthName(m.month, "long")}</td>
                <td className="py-1 text-right">{money(m.incomeCents)}</td>
                <td className="py-1 text-right">{money(m.expenseCents)}</td>
                <td className="py-1 text-right">
                  {formatMoney(
                    m.incomeCents - m.expenseCents,
                    summary.currency,
                    lang,
                    {
                      sign: true,
                    },
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </details>
    </section>
  );
}

function Row(
  { color, label, value }: { color: string; label: string; value: string },
) {
  return (
    <div className="flex items-center justify-between gap-4">
      <span className="inline-flex items-center gap-1.5 text-muted-foreground">
        <span
          className="size-2 rounded-sm"
          style={{ backgroundColor: color }}
        />{" "}
        {label}
      </span>
      <span className="font-medium tabular-nums">{value}</span>
    </div>
  );
}

/** One row of the breakdown: a category with its subcategories (`total`), or what is directly
 *  in a category that has subcategories too, or the uncategorized transactions. */
interface BreakdownRow {
  key: string;
  label: string;
  cents: number;
  depth: number;
  node?: CategoryNode;
}

/**
 * Where the money went (or came from): one bar per top-level category, largest first, its
 * subcategories folded in. A category with subcategories opens to show them (and what is in
 * the category itself), as deep as the tree goes. Bars share one scale, shares are of the total.
 */
function CategoryBreakdown({ summary }: { summary: FinanceSummary }) {
  const finance = useFinance();
  const { t, locale: lang } = useT();
  const [kind, setKind] = useState<"expense" | "income">("expense");
  const [open, setOpen] = useState<Set<string>>(() => new Set());
  const key = kind === "expense" ? "expenseCents" : "incomeCents";
  const tree = finance.categoryTree;

  // What each category holds itself, and with its subcategories.
  const own = new Map<string, number>();
  let uncategorized = 0;
  for (const c of summary.categories) {
    if (c.categoryId && tree.byId.has(c.categoryId)) own.set(c.categoryId, c[key]);
    else uncategorized += c[key];
  }
  const totals = new Map<string, number>();
  const sum = (n: CategoryNode): number => {
    const cents = n.children.reduce((s, k) => s + sum(k), own.get(n.category.id) ?? 0);
    totals.set(n.category.id, cents);
    return cents;
  };
  tree.roots.forEach(sum);

  const label = (c: Category) => `${c.icon ? c.icon + " " : ""}${c.name}`;
  const nodeRows = (nodes: CategoryNode[], depth: number): BreakdownRow[] =>
    nodes.map((n) => ({
      key: n.category.id,
      label: label(n.category),
      cents: totals.get(n.category.id) ?? 0,
      depth,
      node: n,
    })).filter((r) => r.cents > 0).sort((a, b) => b.cents - a.cents);
  const top = nodeRows(tree.roots, 0);
  if (uncategorized > 0) {
    top.push({ key: "none", label: t("finance.uncategorized"), cents: uncategorized, depth: 0 });
    top.sort((a, b) => b.cents - a.cents);
  }
  const total = top.reduce((n, r) => n + r.cents, 0);
  const max = top[0]?.cents ?? 1;

  /** The row and, when it is open, the rows below it. */
  const expand = (r: BreakdownRow): BreakdownRow[] => {
    const children = r.node ? nodeRows(r.node.children, r.depth + 1) : [];
    if (!children.length || !open.has(r.key)) return [r];
    const direct = own.get(r.key) ?? 0;
    const below = direct > 0
      ? [...children, {
        key: `${r.key}:direct`,
        label: t("finance.directlyIn", { name: r.node!.category.name }),
        cents: direct,
        depth: r.depth + 1,
      }].sort((a, b) => b.cents - a.cents)
      : children;
    return [r, ...below.flatMap(expand)];
  };
  const toggle = (id: string) =>
    setOpen((prev) => {
      const next = new Set(prev);
      if (!next.delete(id)) next.add(id);
      return next;
    });

  return (
    <section className="rounded-xl border bg-card p-4">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h2 className="font-semibold">{t("finance.byCategory")}</h2>
        <Tabs
          value={kind}
          onValueChange={(v) => setKind(v as "expense" | "income")}
        >
          <TabsList className="h-8">
            <TabsTrigger value="expense" className="text-xs">
              {t("finance.expenses")}
            </TabsTrigger>
            <TabsTrigger value="income" className="text-xs">
              {t("finance.income")}
            </TabsTrigger>
          </TabsList>
        </Tabs>
      </div>
      {!top.length && <p className="text-sm text-muted-foreground">{t("finance.noData")}</p>}
      <ul className="space-y-2.5">
        {top.flatMap(expand).map((r) => {
          const share = Math.round((r.cents / total) * 100);
          const opens = !!r.node?.children.some((k) => (totals.get(k.category.id) ?? 0) > 0);
          const isOpen = open.has(r.key);
          return (
            <li
              key={r.key}
              className="grid grid-cols-[minmax(7rem,12rem)_1fr_auto] items-center gap-3 text-sm"
            >
              <span
                className="flex min-w-0 items-center gap-1"
                style={{ paddingLeft: `${Math.min(r.depth, 6) * 0.75}rem` }}
              >
                {opens
                  ? (
                    <button
                      type="button"
                      className="flex min-w-0 items-center gap-1 rounded-sm text-left hover:underline"
                      aria-expanded={isOpen}
                      title={t(
                        isOpen ? "finance.hideSubcategories" : "finance.showSubcategories",
                      )}
                      onClick={() => toggle(r.key)}
                    >
                      <ChevronRight
                        className={cn(
                          "size-4 shrink-0 text-muted-foreground transition-transform",
                          isOpen && "rotate-90",
                        )}
                      />
                      <span className="truncate">{r.label}</span>
                    </button>
                  )
                  : (
                    <>
                      {/* where the others have their arrow */}
                      <span className="size-4 shrink-0" />
                      <span
                        className={cn(
                          "truncate",
                          r.depth > 0 && "text-muted-foreground",
                          r.key.endsWith(":direct") && "italic",
                        )}
                      >
                        {r.label}
                      </span>
                    </>
                  )}
              </span>
              <span
                className="h-3 overflow-hidden rounded-r-[4px]"
                title={`${share}%`}
              >
                <span
                  className={cn(
                    "block h-full rounded-r-[4px] bg-(--series-1)",
                    r.depth > 0 && "opacity-60",
                  )}
                  style={{ width: `${Math.max(1, (r.cents / max) * 100)}%` }}
                />
              </span>
              <span className="text-right whitespace-nowrap tabular-nums">
                {formatMoney(r.cents, summary.currency, lang)}
                <span className="ml-2 inline-block w-9 text-xs text-muted-foreground">
                  {share}%
                </span>
              </span>
            </li>
          );
        })}
      </ul>
    </section>
  );
}
