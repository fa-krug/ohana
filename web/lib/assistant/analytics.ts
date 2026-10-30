// Grouped totals and statistics for the assistant, worked out here so the model doesn't have to
// add up rows itself: transactions (counted like every total in the app: a transfer by its net,
// a split booking by its parts) and calendar days per entry type.

import { weekday } from "@/lib/calendar/dates";
import type { EntryRow, TypeRow } from "@/lib/calendar/store";
import { categoryTree } from "@/lib/finance/category-tree";
import { type NetItem, similarKey } from "@/lib/finance/finance";
import type { AccountRow, CategoryRow } from "@/lib/finance/store";
import { median, variance } from "./calc";

export const TX_DIMENSIONS = [
  "month",
  "quarter",
  "year",
  "week",
  "weekday",
  "day",
  "category",
  "account",
  "payee",
  "kind",
] as const;
export type TxDimension = typeof TX_DIMENSIONS[number];
export const TX_STATS = ["avg", "median", "min", "max", "stddev"] as const;
export type TxStat = typeof TX_STATS[number];
export const TX_SORTS = ["key", "total", "count", "income", "expense", "net"] as const;
export type TxSort = typeof TX_SORTS[number];

export const CALENDAR_DIMENSIONS = ["type", "year", "month", "weekday"] as const;
export type CalendarDimension = typeof CALENDAR_DIMENSIONS[number];

const WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const TIME_DIMENSIONS = new Set(["month", "quarter", "year", "week", "weekday", "day"]);
/** Empty months (quarters, years) between the first and the last are listed with zeros, up to
 *  this many months. */
const MAX_FILL_MONTHS = 1200;

/** ISO 8601 week, e.g. "2026-W05": weeks start on Monday, the first has the year's Thursday. */
export function isoWeek(day: string): string {
  const d = new Date(day + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() - (d.getUTCDay() + 6) % 7 + 3); // the week's Thursday
  const year = d.getUTCFullYear();
  const week = Math.floor((d.getTime() - Date.UTC(year, 0, 1)) / 86_400_000 / 7) + 1;
  return `${year}-W${String(week).padStart(2, "0")}`;
}

/** Monday = 0 … Sunday = 6. */
const weekdayIndex = (day: string) => (weekday(day) + 6) % 7;

/** "2026-01" … "2026-12" from the month of `from` to the month of `to`. */
function monthsBetween(from: string, to: string): string[] {
  const out: string[] = [];
  let y = +from.slice(0, 4), m = +from.slice(5, 7);
  const end = to.slice(0, 7);
  for (let i = 0; i < MAX_FILL_MONTHS; i++) {
    const ym = `${y}-${String(m).padStart(2, "0")}`;
    if (ym > end) break;
    out.push(ym);
    if (++m > 12) [y, m] = [y + 1, 1];
  }
  return out;
}

const round = (x: number) => Math.round(x) || 0;

type Key = { key: string; order: (string | number)[]; fields: Record<string, unknown> };

/** One key per dimension, with the fields the result shows and how groups are ordered. */
function combine(keys: Key[]): Key {
  return {
    key: keys.map((k) => k.key).join("|"),
    order: keys.flatMap((k) => k.order),
    fields: Object.assign({}, ...keys.map((k) => k.fields)),
  };
}

function compareOrder(a: (string | number)[], b: (string | number)[]): number {
  for (let i = 0; i < a.length; i++) {
    if (a[i] < b[i]) return -1;
    if (a[i] > b[i]) return 1;
  }
  return 0;
}

/** Keys of the time dimensions both analyses share. */
function timeKey(dim: string, day: string): Key {
  const year = +day.slice(0, 4);
  switch (dim) {
    case "month":
      return { key: day.slice(0, 7), order: [day.slice(0, 7)], fields: { month: day.slice(0, 7) } };
    case "quarter": {
      const q = `${year}-Q${Math.floor((+day.slice(5, 7) - 1) / 3) + 1}`;
      return { key: q, order: [q], fields: { quarter: q } };
    }
    case "year":
      return { key: String(year), order: [year], fields: { year } };
    case "week": {
      const w = isoWeek(day);
      return { key: w, order: [w], fields: { week: w } };
    }
    case "weekday": {
      const i = weekdayIndex(day);
      return { key: WEEKDAYS[i], order: [i], fields: { weekday: WEEKDAYS[i] } };
    }
    default:
      return { key: day, order: [day], fields: { day } };
  }
}

export interface TxAnalysis {
  groups: Record<string, unknown>[];
  total: Record<string, unknown>;
  /** With one dimension: the average and median group (per month, say), over all groups. */
  perGroup?: Record<string, number>;
}

/** Count, income, expenses, net and the asked statistics of the amounts. */
function figures(amounts: number[], stats: TxStat[]) {
  let income = 0, expense = 0;
  for (const a of amounts) {
    if (a > 0) income += a;
    else expense -= a;
  }
  const out: Record<string, number> = {
    count: amounts.length,
    incomeCents: income,
    expenseCents: expense,
    netCents: income - expense,
  };
  if (!amounts.length) return out;
  for (const s of stats) {
    if (s === "avg") out.avgCents = round((income - expense) / amounts.length);
    if (s === "median") out.medianCents = round(median(amounts));
    if (s === "min") out.minCents = amounts.reduce((m, a) => Math.min(m, a));
    if (s === "max") out.maxCents = amounts.reduce((m, a) => Math.max(m, a));
    if (s === "stddev" && amounts.length > 1) out.stddevCents = round(Math.sqrt(variance(amounts)));
  }
  return out;
}

/**
 * Groups the items by up to two dimensions and sums them up per group. Statistics (avg,
 * median, …) are of the single amounts (negative = money out). Time groups are in order;
 * others by their volume (income + expenses), largest first, unless `sortBy` says otherwise.
 * Categories are a tree: with `categoryLevel` (1 = top level) an item counts for its
 * category's ancestor at that level (or its own category, if that isn't as deep); without, for
 * its own category.
 */
export function analyzeTransactions(input: {
  items: NetItem[];
  groupBy: TxDimension[];
  stats: TxStat[];
  sortBy?: TxSort;
  order?: "asc" | "desc";
  categoryLevel?: number;
  categories: CategoryRow[];
  accounts: AccountRow[];
  from?: string;
  to?: string;
}): TxAnalysis {
  const { items, groupBy, stats } = input;
  const tree = categoryTree(input.categories);
  const accounts = new Map(input.accounts.map((a) => [a.id, a]));
  const keyOf = (dim: TxDimension, it: NetItem): Key => {
    switch (dim) {
      case "category": {
        const own = it.categoryId ? tree.byId.get(it.categoryId) : undefined;
        const c = own && input.categoryLevel ? tree.atLevel(own.id, input.categoryLevel) : own;
        const id = c?.id ?? it.categoryId;
        return {
          key: id ?? "",
          order: [c ? tree.index(c.id) : Infinity],
          fields: {
            category: id,
            categoryName: c?.name ?? null,
            ...(c && tree.depth(c.id) > 1 ? { categoryPath: tree.path(c.id) } : {}),
          },
        };
      }
      case "account": {
        const a = it.accountId ? accounts.get(it.accountId) : undefined;
        return {
          key: it.accountId ?? "",
          order: [a ? a.position : Infinity],
          fields: { account: it.accountId, accountName: a?.name ?? null },
        };
      }
      case "payee": {
        const key = similarKey(it);
        return { key, order: [key], fields: {} };
      }
      case "kind": {
        const kind = it.amountCents > 0 ? "income" : "expense";
        return { key: kind, order: [kind], fields: { kind } };
      }
      default:
        return timeKey(dim, it.day);
    }
  };

  type Group = Key & { amounts: number[]; payees?: Map<string, number> };
  const groups = new Map<string, Group>();
  const byPayee = groupBy.includes("payee");
  for (const it of items) {
    const k = combine(groupBy.map((d) => keyOf(d, it)));
    let g = groups.get(k.key);
    if (!g) groups.set(k.key, g = { ...k, amounts: [], payees: byPayee ? new Map() : undefined });
    g.amounts.push(it.amountCents);
    // A payee group is named after the spelling it has most often.
    const name = (it.payee || it.description).trim().slice(0, 80);
    g.payees?.set(name, (g.payees.get(name) ?? 0) + 1);
  }

  // One dimension of whole months, quarters or years: the empty ones count too (as 0).
  const days = items.map((it) => it.day).sort();
  const from = input.from ?? days[0], to = input.to ?? days.at(-1);
  if (
    groupBy.length === 1 && ["month", "quarter", "year"].includes(groupBy[0]) && from && to
  ) {
    for (const ym of monthsBetween(from, to)) {
      const k = timeKey(groupBy[0], `${ym}-01`);
      if (!groups.has(k.key)) groups.set(k.key, { ...k, amounts: [] });
    }
  }

  const rows = [...groups.values()].map((g) => {
    const payee = g.payees &&
      [...g.payees].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))[0]?.[0];
    const fields = g.payees ? { payee: payee ?? "" } : {};
    const row: Record<string, unknown> = { ...g.fields, ...fields, ...figures(g.amounts, stats) };
    return { g, row };
  });
  const sortBy = input.sortBy ?? (TIME_DIMENSIONS.has(groupBy[0]) ? "key" : "total");
  const desc = (input.order ?? (sortBy === "key" ? "asc" : "desc")) === "desc";
  const metric = (r: Record<string, unknown>) => {
    const n = (k: string) => Number(r[k]);
    if (sortBy === "count") return n("count");
    if (sortBy === "income") return n("incomeCents");
    if (sortBy === "expense") return n("expenseCents");
    if (sortBy === "net") return n("netCents");
    return n("incomeCents") + n("expenseCents");
  };
  rows.sort((a, b) => {
    const c = sortBy === "key"
      ? compareOrder(a.g.order, b.g.order)
      : metric(a.row) - metric(b.row) || compareOrder(a.g.order, b.g.order);
    return desc ? -c : c;
  });

  const result: TxAnalysis = {
    groups: rows.map((r) => r.row),
    total: figures(items.map((it) => it.amountCents), stats),
  };
  if (groupBy.length === 1 && rows.length) {
    const of = (k: string) => rows.map((r) => Number(r.row[k]));
    result.perGroup = {
      groups: rows.length,
      avgIncomeCents: round(of("incomeCents").reduce((s, x) => s + x, 0) / rows.length),
      avgExpenseCents: round(of("expenseCents").reduce((s, x) => s + x, 0) / rows.length),
      avgNetCents: round(of("netCents").reduce((s, x) => s + x, 0) / rows.length),
      medianIncomeCents: round(median(of("incomeCents"))),
      medianExpenseCents: round(median(of("expenseCents"))),
      medianNetCents: round(median(of("netCents"))),
    };
  }
  return result;
}

/**
 * Days per group in the calendar: per entry type (a day counts once for each of its types),
 * year, month and / or weekday. Without the type dimension a day counts once, whatever entries
 * it has. `weekdaysOnly` leaves out Saturdays and Sundays; `skipDaysOff` leaves out entries on
 * days that also have a "day off" entry (a vacation day on a public holiday costs nothing).
 */
export function analyzeCalendar(input: {
  types: TypeRow[];
  entries: EntryRow[];
  from: string;
  to: string;
  /** Only entries of these type ids (any year). */
  only?: Set<string>;
  groupBy: CalendarDimension[];
  weekdaysOnly: boolean;
  skipDaysOff: boolean;
}) {
  const { from, to, only, groupBy } = input;
  const typeOf = new Map(input.types.map((t) => [`${t.year}|${t.id}`, t]));
  const byDay = new Map<string, TypeRow[]>();
  for (const e of input.entries) {
    const t = typeOf.get(`${e.day.slice(0, 4)}|${e.type_id}`);
    if (t) byDay.set(e.day, [...(byDay.get(e.day) ?? []), t]);
  }
  // Types are per year: one group per type id, named and ordered as in the latest year.
  const latest = new Map<string, TypeRow>();
  for (const t of input.types) {
    if (t.year >= +from.slice(0, 4) && t.year <= +to.slice(0, 4) && (!only || only.has(t.id))) {
      if (!latest.has(t.id) || latest.get(t.id)!.year < t.year) latest.set(t.id, t);
    }
  }
  const typeKey = (t: TypeRow): Key => {
    const l = latest.get(t.id) ?? t;
    return { key: t.id, order: [l.position, l.name], fields: { type: t.id, typeName: l.name } };
  };
  const keyOf = (dim: CalendarDimension, day: string, t?: TypeRow): Key =>
    dim === "type" ? typeKey(t!) : timeKey(dim, day);

  const groups = new Map<string, Key & { days: number }>();
  const add = (k: Key) => {
    const g = groups.get(k.key);
    if (g) g.days++;
    else groups.set(k.key, { ...k, days: 1 });
  };
  let total = 0;
  for (const [day, types] of byDay) {
    if (day < from || day > to) continue;
    if (input.weekdaysOnly && weekdayIndex(day) > 4) continue;
    const dayOff = types.some((t) => t.role === "day_off");
    const counted = types.filter((t) =>
      (!only || only.has(t.id)) && !(input.skipDaysOff && dayOff && t.role !== "day_off")
    );
    if (!counted.length) continue;
    total++;
    if (groupBy.includes("type")) {
      for (const t of counted) add(combine(groupBy.map((d) => keyOf(d, day, t))));
    } else {
      add(combine(groupBy.map((d) => keyOf(d, day))));
    }
  }
  // One dimension: types without days, and months or years without any, count too (as 0).
  if (groupBy.length === 1) {
    const empty: Key[] = groupBy[0] === "type"
      ? [...latest.values()].map(typeKey)
      : groupBy[0] === "month" || groupBy[0] === "year"
      ? monthsBetween(from, to).map((ym) => timeKey(groupBy[0], `${ym}-01`))
      : [];
    for (const k of empty) if (!groups.has(k.key)) groups.set(k.key, { ...k, days: 0 });
  }
  return {
    groups: [...groups.values()].sort((a, b) => compareOrder(a.order, b.order))
      .map((g) => ({ ...g.fields, days: g.days })),
    days: total,
  };
}
