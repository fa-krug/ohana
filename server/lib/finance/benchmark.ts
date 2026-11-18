// The statistic average the finance overview compares the family's months with (e.g. a
// statistics office's household spending): ranges per month for income, expenses and categories.
// Stored as JSON in fin_settings.benchmark; the app compares (benchmarkValues).

import { HttpError, objectOf } from "@/lib/api/http";
import { cleanAmount } from "./amounts";
import { findCategory } from "./category-tree";
import type { Benchmark, CategoryRow, CentsRange, FinanceSettingsRow } from "./store";

const MAX_BENCHMARK_LABEL = 120;

/** A range per month from a number (a single value) or {lowCents, highCents} (one of them is
 *  enough for a single value); null when none is given. Not negative, low not above high. */
function cleanCentsRange(v: unknown, field: string): CentsRange | null {
  if (v === null || v === undefined || v === "") return null;
  const cents = (n: unknown, name: string) => {
    if (n === null || n === undefined) return null;
    const c = cleanAmount(n, name);
    if (c < 0) throw new HttpError(400, `${name} must not be negative`);
    return c;
  };
  if (typeof v === "number") {
    const n = cents(v, field)!;
    return { lowCents: n, highCents: n };
  }
  const r = objectOf(v, field);
  const low = cents(r.lowCents, `${field}.lowCents`);
  const high = cents(r.highCents, `${field}.highCents`);
  if (low === null && high === null) return null;
  if (low !== null && high !== null && low > high) {
    throw new HttpError(400, `${field}.lowCents must not be above highCents`);
  }
  return { lowCents: low ?? high!, highCents: high ?? low! };
}

/**
 * A statistic average from {label, income, expense, categories: [{categoryId (id, name or
 * path), lowCents, highCents}]}: amounts per month, each a range {lowCents, highCents} or a
 * single value (a number, or a category's `cents`). Null (or one without any amount) clears it.
 * A category given twice keeps its last range. Within a category money in and out always
 * cancel out (`net`, from older apps, is ignored).
 */
export function cleanBenchmark(raw: unknown, categories: CategoryRow[]): Benchmark | null {
  if (raw === null) return null;
  const b = objectOf(raw, "benchmark");
  if (b.label !== undefined && typeof b.label !== "string") {
    throw new HttpError(400, "benchmark.label must be a string");
  }
  if (b.categories !== undefined && b.categories !== null && !Array.isArray(b.categories)) {
    throw new HttpError(400, "benchmark.categories must be an array");
  }
  const out: Benchmark = {
    label: ((b.label as string | undefined) ?? "").trim().slice(0, MAX_BENCHMARK_LABEL),
    income: cleanCentsRange(b.income, "benchmark.income"),
    expense: cleanCentsRange(b.expense, "benchmark.expense"),
    categories: benchmarkCategories((b.categories ?? []) as unknown[], categories),
  };
  return out.income || out.expense || out.categories.length ? out : null;
}

/** A statistic average's category ranges; a category given twice keeps its last range. */
function benchmarkCategories(list: unknown[], categories: CategoryRow[]): Benchmark["categories"] {
  const byCategory = new Map<string, CentsRange>();
  for (const raw of list) {
    const c = objectOf(raw, "Each benchmark category");
    const id = findCategory(categories, c.categoryId ?? c.category).id;
    const range = cleanCentsRange(
      c.cents ?? { lowCents: c.lowCents, highCents: c.highCents },
      "benchmark.categories",
    );
    if (range) byCategory.set(id, range);
    else byCategory.delete(id);
  }
  return [...byCategory].map(([categoryId, range]) => ({ categoryId, ...range }));
}

/** The statistic average without categories that are gone since. */
export function benchmarkOf(settings: FinanceSettingsRow | null, categories: CategoryRow[]) {
  const b = settings?.benchmark;
  if (!b) return null;
  const ids = new Set(categories.map((c) => c.id));
  return {
    ...b,
    categories: b.categories.filter((c) => ids.has(c.categoryId)),
    net: true, // older apps: money in and out within a category always cancel out
  };
}
