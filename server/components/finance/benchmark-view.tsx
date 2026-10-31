"use client";

// Where the period is within the statistic average (family-planner's BenchmarkView.tsx).

import { formatMoney } from "@/lib/finance/money";
import { useT } from "@/lib/i18n/provider";
import type { TVars } from "@/lib/i18n/translate";
import { cn } from "@/lib/utils";
import type { CentsRange } from "./api";
import type { CategoryTree } from "./category-tree";
import { columnOf } from "./comparison-view";
import { useFinance } from "./context";

type T = (key: string, vars?: TVars) => string;

interface Row {
  key: string;
  label: string;
  range: CentsRange;
  /** Per month; null when there is nothing to compare yet. */
  cents: number | null;
  /** Above the range is good (income) or bad (expenses). */
  good: "higher" | "lower";
}

/** A top-level category's range: its own, or else the sum of those set on its subcategories
 *  (none when neither is set). */
function categoryRange(
  tree: CategoryTree,
  own: Map<string, CentsRange>,
  id: string,
): CentsRange | null {
  if (own.has(id)) return own.get(id)!;
  const below = [...tree.subtree(id)].flatMap((
    k,
  ) => (own.has(k) ? [own.get(k)!] : []));
  if (!below.length) return null;
  return {
    lowCents: below.reduce((n, r) => n + r.lowCents, 0),
    highCents: below.reduce((n, r) => n + r.highCents, 0),
  };
}

/** Where a value is against a range, in words, and whether that is good, bad or neither. */
function standing(
  row: Row,
  t: T,
): { text: string; tone: "good" | "bad" | "neutral" } | null {
  const { cents, good } = row;
  const { lowCents: low, highCents: high } = row.range;
  if (cents === null) return null;
  const tone = (
    higher: boolean,
  ) => (higher === (good === "higher") ? "good" : "bad");
  // How far outside the range, in percent of its nearer end (0: inside, or less than 0.5 %).
  const off = cents < low
    ? -Math.round(((low - cents) / low) * 100)
    : cents > high
    ? (high ? Math.round(((cents - high) / high) * 100) : Infinity)
    : 0;
  if (off === Infinity) {
    return { text: t("finance.benchmark.aboveZero"), tone: tone(true) };
  }
  if (off > 0) {
    return { text: t("finance.benchmark.above", { n: off }), tone: tone(true) };
  }
  if (off < 0) {
    return {
      text: t("finance.benchmark.below", { n: -off }),
      tone: tone(false),
    };
  }
  if (low === high || cents < low || cents > high) {
    return { text: t("finance.benchmark.on"), tone: "neutral" };
  }
  const upper = (cents - low) / (high - low) >= 0.5;
  return {
    text: t(
      upper ? "finance.benchmark.upperHalf" : "finance.benchmark.lowerHalf",
    ),
    tone: "neutral",
  };
}

/** The range as a band on a track, and the value as a line across it; each row has its own
 *  scale, from 0 to a bit beyond the larger of the two. */
function RangeBar(
  { range, cents }: { range: CentsRange; cents: number | null },
) {
  const max = Math.max(range.highCents, cents ?? 0) * 1.25 || 1;
  const at = (v: number) => `${(v / max) * 100}%`;
  return (
    <div className="relative h-5" aria-hidden>
      <div className="absolute inset-x-0 top-1/2 h-1.5 -translate-y-1/2 rounded-full bg-muted" />
      {range.lowCents === range.highCents
        ? (
          // A single value: a tick of the range's color.
          <div
            className="absolute top-0.5 h-4 w-1 -translate-x-1/2 rounded-full bg-(--series-1) opacity-70"
            style={{ left: at(range.lowCents) }}
          />
        )
        : (
          <div
            className="absolute top-1/2 h-3 -translate-y-1/2 rounded-[4px] bg-(--series-1) opacity-35"
            style={{
              left: at(range.lowCents),
              width: at(range.highCents - range.lowCents),
            }}
          />
        )}
      {cents !== null && (
        <div
          className="absolute top-0 h-5 w-[3px] -translate-x-1/2 rounded-full bg-foreground"
          style={{ left: at(cents) }}
        />
      )}
    </div>
  );
}

/**
 * Where the period is within the statistic average the family set: income, expenses and the
 * top-level categories that have a range, each as a band with the period's value (per month,
 * like the first column of the comparison) on it. Hidden while no statistic average is set.
 */
export function BenchmarkView() {
  const finance = useFinance();
  const { t, locale: lang } = useT();
  const benchmark = finance.overview?.benchmark;
  const comparisons = finance.comparisons;
  if (!benchmark || !comparisons) return null;
  const tree = finance.categoryTree;
  const column = columnOf(comparisons[0], tree, lang, t);
  const values = column.values;
  // Averages per month in whole units, like the comparison.
  const money = (cents: number) => formatMoney(cents, finance.currency, lang, { whole: true });

  const rows: Row[] = [];
  if (benchmark.income) {
    rows.push({
      key: "income",
      label: t("finance.income"),
      range: benchmark.income,
      cents: values?.incomeCents ?? null,
      good: "higher",
    });
  }
  if (benchmark.expense) {
    rows.push({
      key: "expense",
      label: t("finance.expenses"),
      range: benchmark.expense,
      cents: values?.expenseCents ?? null,
      good: "lower",
    });
  }
  const own = new Map(benchmark.categories.map((c) => [c.categoryId, c]));
  for (const { category: c } of tree.roots) {
    const range = categoryRange(tree, own, c.id);
    if (!range) continue;
    const side = c.kind === "income" ? "income" : "expense";
    rows.push({
      key: c.id,
      label: `${c.icon ? c.icon + " " : ""}${c.name}`,
      range,
      cents: values ? values[side].get(c.id) ?? 0 : null,
      good: side === "income" ? "higher" : "lower",
    });
  }
  const span = (r: CentsRange) =>
    r.lowCents === r.highCents ? money(r.lowCents) : `${money(r.lowCents)} – ${money(r.highCents)}`;

  return (
    <section className="rounded-xl border bg-card p-4">
      <div className="mb-1 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <h2 className="font-semibold">{t("finance.benchmark.title")}</h2>
        <span className="text-xs text-muted-foreground">
          {t("finance.compare.perMonth")}
        </span>
      </div>
      <p className="mb-3 text-xs text-muted-foreground">
        {[
          benchmark.label,
          values
            ? t("finance.benchmark.basis", {
              period: column.title,
              detail: column.detail,
            })
            : t("finance.compare.nothingYet"),
        ].filter(Boolean).join(" · ")}
      </p>
      <ul className="space-y-3">
        {rows.map((row) => {
          const s = standing(row, t);
          return (
            <li
              key={row.key}
              className="grid grid-cols-[1fr_auto] items-center gap-x-3 text-sm sm:grid-cols-[minmax(5.5rem,11rem)_1fr_auto]"
            >
              {/* Phones: the bar gets a line of its own, below the name and the value. */}
              <span
                className="col-start-1 row-start-1 truncate"
                title={row.label}
              >
                {row.label}
              </span>
              <div className="col-span-2 row-start-2 min-w-0 sm:col-span-1 sm:col-start-2 sm:row-start-1">
                <RangeBar range={row.range} cents={row.cents} />
                <div className="truncate text-[11px] text-muted-foreground tabular-nums">
                  {span(row.range)}
                </div>
              </div>
              <div className="col-start-2 row-start-1 text-right whitespace-nowrap tabular-nums sm:col-start-3">
                <div className="font-medium">
                  {row.cents === null ? "—" : money(row.cents)}
                </div>
                {s && (
                  <div
                    className={cn(
                      "text-[11px]",
                      s.tone === "good" && "text-ok",
                      s.tone === "bad" && "text-gap",
                      s.tone === "neutral" && "text-muted-foreground",
                    )}
                  >
                    {s.text}
                  </div>
                )}
              </div>
            </li>
          );
        })}
      </ul>
      <p className="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-muted-foreground">
        <span className="inline-flex items-center gap-1.5">
          <span className="h-2.5 w-4 rounded-[3px] bg-(--series-1) opacity-35" />
          {t("finance.benchmark.legendRange")}
        </span>
        <span className="inline-flex items-center gap-1.5">
          <span className="h-3 w-[3px] rounded-full bg-foreground" />
          {t("finance.benchmark.legendValue", { period: column.title })}
        </span>
      </p>
    </section>
  );
}
