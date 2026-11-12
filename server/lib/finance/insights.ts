// What the finance overview points out (GET /finance/insights, the assistant's
// finance_insights): where the period's spending grew against the family's own usual month
// (changes), the payments that come back regularly (recurring), small amounts that add up
// (frequent), and what looks wrong in the data (issues: likely duplicates, transfers without
// their other leg, a transaction far from its payee's usual category or amount; plus the
// uncategorized share, transfers not combined yet and bank balances that differ). Everything is
// counted like the summary (netItems: a transfer group once by its net, a split booking by its
// parts). Payees are told apart by similarKey ("REWE Markt 1234" = "Rewe Markt 5678"). Editors
// hide an issue or a regular payment for good with a dismissal ("Looks fine").

import { and, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { finInsightDismissals } from "@/lib/db/schema";
import { addDays, diffDays } from "@/lib/calendar/dates";
import { categoryTree } from "./category-tree";
import {
  groupOf,
  type Links,
  listAccounts,
  loadLinks,
  merchantOf,
  type NetItem,
  netItems,
  publicTransaction,
  similarKey,
  transferPairs,
} from "./finance";
import type { FinanceStore as Store, TransactionRow } from "./store";

/** How many completed months before the period are its baseline. */
export const BASELINE_MONTHS = 12;
/** A change counts from this much more per month (cents) … */
const MIN_CHANGE_CENTS = 2000;
/** … and this share of what was usual. */
const MIN_CHANGE_SHARE = 0.15;
const MAX_CHANGES = 6;
const MAX_CHANGE_PAYEES = 3;
/** Regular payments are looked for this far back (days). */
const RECURRING_LOOKBACK = 800;
/** Amounts within this factor of each other may be the same payment (a price change of 28 %
 *  stays one series; 1 € and 10 € at one payee are two). */
const SERIES_RATIO = 1.4;
const MAX_RECURRING = 40;
/** "Small" amounts (cents) for the ones that add up. */
export const SMALL_CENTS = 3000;
const MAX_FREQUENT = 6;
/** Two bookings this many days apart may be one booking twice. */
const DUPLICATE_DAYS = 2;
/** A payee's usual category: at least this many categorized transactions … */
const USUAL_MIN = 4;
/** … this share of them in one category. */
const USUAL_SHARE = 0.75;
/** An unusual amount: at least this many earlier ones, this factor of their median and this much
 *  (cents) above it. */
const AMOUNT_MIN = 5;
const AMOUNT_FACTOR = 3;
const AMOUNT_MIN_CENTS = 5000;
const MAX_ISSUES = 60;
/** Words that name a transfer between one's own accounts (or a card's statement). */
const TRANSFER_RE =
  /umbuchung|übertrag|uebertrag|eigenüberweisung|kreditkarten-?abrechnung|kartenabrechnung|visa-?abrechnung|\btransfer\b|sparplan|\bsavings\b/i;

export const INSIGHT_KINDS = ["duplicate", "unpaired", "category", "amount", "recurring"] as const;
export type InsightKind = (typeof INSIGHT_KINDS)[number];

export type Interval = "week" | "month" | "quarter" | "half" | "year";

/** Per interval: its nominal length, how far a gap may be off it, how many occurrences show it,
 *  how often a year it comes, and after how many days without one it counts as stopped. */
const INTERVALS: Record<Interval, { days: number; tol: number; min: number; perYear: number; late: number }> = {
  week: { days: 7, tol: 2, min: 6, perYear: 52, late: 16 },
  month: { days: 30.44, tol: 5, min: 3, perYear: 12, late: 45 },
  quarter: { days: 91.3, tol: 12, min: 3, perYear: 4, late: 120 },
  half: { days: 182.6, tol: 15, min: 2, perYear: 2, late: 215 },
  year: { days: 365.25, tol: 20, min: 2, perYear: 1, late: 400 },
};

export type Change = {
  /** null: uncategorized. */
  categoryId: string | null;
  /** Per month: in the period, as usual (the baseline's average month), the difference. */
  currentCents: number;
  usualCents: number;
  deltaCents: number;
  /** The payees that grew most, per month. */
  payees: { key: string; name: string; count: number; currentCents: number; usualCents: number; deltaCents: number }[];
};

export type Recurring = {
  /** The dismissal key ("recurring:<payee>:<interval>"). */
  key: string;
  /** similarKey of the payee (GET /finance/transactions?payee=). */
  payee: string;
  name: string;
  categoryId: string | null;
  accountId: string | null;
  interval: Interval;
  count: number;
  /** The latest amount (positive: money out), and per year at that amount. */
  amountCents: number;
  yearlyCents: number;
  firstDay: string;
  lastDay: string;
  /** When the next one is due. */
  nextDay: string;
  /** active, new (first within ~3 months), stopped (overdue: cancelled, or paid otherwise). */
  status: "active" | "new" | "stopped";
  /** The amount changed within the last year: from, since. */
  change: { previousCents: number; since: string } | null;
};

export type Frequent = {
  payee: string;
  name: string;
  categoryId: string | null;
  count: number;
  totalCents: number;
  averageCents: number;
  perMonthCents: number;
};

export type Issue = {
  /** The dismissal key: "<kind>:<transaction ids>". */
  key: string;
  kind: Exclude<InsightKind, "recurring">;
  day: string;
  transactions: ReturnType<typeof publicTransaction>[];
  /** category: the payee's usual category; amount: its usual (median) amount, positive. */
  usualCategoryId?: string;
  usualCents?: number;
};

export type Insights = {
  currency: string;
  from: string | null;
  to: string | null;
  today: string;
  /** The period runs (its end is after today): its numbers are "so far". */
  partial: boolean;
  /** The months the changes compare with; null without earlier data (or for all time). */
  baseline: { from: string; to: string; months: number } | null;
  /** The months of the period the changes and the frequent ones are counted over. */
  months: number;
  changes: Change[];
  recurring: Recurring[];
  /** The active regular payments per year together. */
  recurringYearlyCents: number;
  frequent: Frequent[];
  issues: Issue[];
  uncategorized: { count: number; incomeCents: number; expenseCents: number };
  /** Pairs that look like transfers, not combined yet (POST /finance/transfers/auto). */
  transferSuggestions: number;
  /** Linked accounts whose balance at the bank differs from Ohana's. */
  balanceDrift: { accountId: string; bankCents: number; ohanaCents: number; at: string | null }[];
  /** How many were hidden by a dismissal. */
  dismissed: number;
};

// ------------------------------------------------------------------ months

const monthOf = (day: string) => day.slice(0, 7);

function addMonths(month: string, n: number): string {
  const [y, m] = month.split("-").map(Number);
  const i = y * 12 + (m - 1) + n;
  return `${String(Math.floor(i / 12)).padStart(4, "0")}-${String((i % 12) + 1).padStart(2, "0")}`;
}

/** The months from a to b (YYYY-MM), both counted; 0 when b is before a. */
export function monthsBetween(a: string, b: string): number {
  const [ya, ma] = a.split("-").map(Number);
  const [yb, mb] = b.split("-").map(Number);
  return Math.max(0, (yb - ya) * 12 + (mb - ma) + 1);
}

function lastDayOf(month: string): string {
  return addDays(`${addMonths(month, 1)}-01`, -1);
}

const per = (cents: number, months: number) => (months > 0 ? Math.round(cents / months) : 0);

/** The text a payee goes by: the newest item's payee, else its description. */
function nameOf(t: { payee: string; description: string }): string {
  const s = (t.payee.trim() || t.description.trim()).replace(/\s+/g, " ");
  return s.length > 60 ? `${s.slice(0, 59)}…` : s;
}

function median(values: number[]): number {
  const s = [...values].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : Math.round((s[mid - 1] + s[mid]) / 2);
}

const inRange = (day: string, from?: string | null, to?: string | null) =>
  (!from || day >= from) && (!to || day <= to);

// ------------------------------------------------------------------ changes

/** The period's expenses per month against the baseline's, per category, the largest increases
 *  first, each with the payees that grew most. */
export function spendingChanges(
  items: NetItem[],
  period: { from: string; to: string; months: number },
  baseline: { from: string; to: string; months: number },
): Change[] {
  type Sums = { current: number; usual: number; count: number; name: string; day: string };
  const cats = new Map<string | null, { current: number; usual: number; payees: Map<string, Sums> }>();
  for (const it of items) {
    if (it.amountCents >= 0) continue;
    const current = inRange(it.day, period.from, period.to);
    if (!current && !inRange(it.day, baseline.from, baseline.to)) continue;
    const cents = -it.amountCents;
    const c = cats.get(it.categoryId) ?? { current: 0, usual: 0, payees: new Map() };
    const key = similarKey(it);
    const p = c.payees.get(key) ?? { current: 0, usual: 0, count: 0, name: "", day: "" };
    if (current) {
      c.current += cents;
      p.current += cents;
      p.count++;
    } else {
      c.usual += cents;
      p.usual += cents;
    }
    // The name of its newest transaction.
    if (it.day >= p.day) {
      p.day = it.day;
      p.name = nameOf(it);
    }
    c.payees.set(key, p);
    cats.set(it.categoryId, c);
  }
  const out: Change[] = [];
  for (const [categoryId, c] of cats) {
    const currentCents = per(c.current, period.months);
    const usualCents = per(c.usual, baseline.months);
    const deltaCents = currentCents - usualCents;
    if (deltaCents < MIN_CHANGE_CENTS || deltaCents < usualCents * MIN_CHANGE_SHARE) continue;
    const payees = [...c.payees].map(([key, p]) => {
      const cur = per(p.current, period.months), usual = per(p.usual, baseline.months);
      return { key, name: p.name, count: p.count, currentCents: cur, usualCents: usual, deltaCents: cur - usual };
    })
      .filter((p) => p.key && p.deltaCents > 0)
      .sort((a, b) => b.deltaCents - a.deltaCents)
      .slice(0, MAX_CHANGE_PAYEES);
    out.push({ categoryId, currentCents, usualCents, deltaCents, payees });
  }
  return out.sort((a, b) => b.deltaCents - a.deltaCents).slice(0, MAX_CHANGES);
}

// ------------------------------------------------------------------ recurring

/** The interval of a series of days (sorted), if its gaps are regular enough. */
function intervalOf(days: string[]): Interval | null {
  if (days.length < 2) return null;
  const gaps = days.slice(1).map((d, i) => diffDays(days[i], d));
  const m = median(gaps);
  for (const [name, iv] of Object.entries(INTERVALS) as [Interval, (typeof INTERVALS)[Interval]][]) {
    if (days.length < iv.min || Math.abs(m - iv.days) > iv.tol) continue;
    const regular = gaps.filter((g) => Math.abs(g - iv.days) <= iv.tol).length;
    if (regular / gaps.length >= 0.75) return name;
  }
  return null;
}

/** Payments that come back regularly (expenses only), up to `today`: by payee, then by amount
 *  (amounts within SERIES_RATIO of each other are one series), each series whose gaps keep to
 *  a week, a month, a quarter, half a year or a year. Stopped ones show for half a year or so. */
export function recurringPayments(items: NetItem[], today: string): Recurring[] {
  const since = addDays(today, -RECURRING_LOOKBACK);
  const byPayee = new Map<string, NetItem[]>();
  for (const it of items) {
    if (it.amountCents >= 0 || it.day > today || it.day < since) continue;
    const key = similarKey(it);
    if (!key) continue;
    byPayee.set(key, [...(byPayee.get(key) ?? []), it]);
  }
  const out: Recurring[] = [];
  for (const [payee, all] of byPayee) {
    // Series by amount: chained while each is within SERIES_RATIO of the one before.
    const byAmount = [...all].sort((a, b) => b.amountCents - a.amountCents); // smallest out first
    const series: NetItem[][] = [];
    for (const it of byAmount) {
      const last = series.at(-1)?.at(-1);
      if (last && -it.amountCents <= -last.amountCents * SERIES_RATIO) series.at(-1)!.push(it);
      else series.push([it]);
    }
    for (const s of series) {
      s.sort((a, b) => a.day.localeCompare(b.day));
      // At most one a day: two the same day aren't a rhythm.
      const days = [...new Set(s.map((t) => t.day))];
      const interval = intervalOf(days);
      if (!interval) continue;
      const iv = INTERVALS[interval];
      const last = s.at(-1)!;
      const idle = diffDays(last.day, today);
      if (idle > iv.late + Math.max(iv.days * 2, 180)) continue; // long gone
      const amountCents = -last.amountCents;
      // The latest amount's run: when it started, and what it was before.
      let i = s.length - 1;
      while (i > 0 && s[i - 1].amountCents === last.amountCents) i--;
      const before = i > 0 ? -s[i - 1].amountCents : null;
      const changed = before !== null && Math.abs(before - amountCents) >= Math.max(10, before * 0.01) &&
        diffDays(s[i].day, today) <= 365;
      out.push({
        key: `recurring:${payee.replaceAll(" ", "_")}:${interval}`,
        payee,
        name: nameOf(last),
        categoryId: last.categoryId,
        accountId: last.accountId,
        interval,
        count: s.length,
        amountCents,
        yearlyCents: amountCents * iv.perYear,
        firstDay: s[0].day,
        lastDay: last.day,
        nextDay: addDays(last.day, Math.round(iv.days)),
        status: idle > iv.late
          ? "stopped"
          : (interval === "week" || interval === "month") && diffDays(s[0].day, today) <= 100
          ? "new"
          : "active",
        change: changed ? { previousCents: before!, since: s[i].day } : null,
      });
    }
  }
  const rank = (r: Recurring) => (r.status === "stopped" ? 1 : 0);
  return out.sort((a, b) => rank(a) - rank(b) || b.yearlyCents - a.yearlyCents).slice(0, MAX_RECURRING);
}

// ------------------------------------------------------------------ frequent small amounts

/** Payees with many small expenses in the items (the period's), the largest totals first;
 *  `skip`: payees already shown as regular payments. */
export function frequentSmall(items: NetItem[], months: number, skip: Set<string>): Frequent[] {
  const byPayee = new Map<string, { items: NetItem[] }>();
  for (const it of items) {
    if (it.amountCents >= 0 || -it.amountCents > SMALL_CENTS) continue;
    const key = similarKey(it);
    if (!key || skip.has(key)) continue;
    const g = byPayee.get(key) ?? { items: [] };
    g.items.push(it);
    byPayee.set(key, g);
  }
  const min = Math.max(4, Math.ceil(2 * months));
  return [...byPayee].filter(([, g]) => g.items.length >= min).map(([payee, g]) => {
    const total = g.items.reduce((s, t) => s - t.amountCents, 0);
    const newest = g.items.reduce((a, b) => (b.day > a.day ? b : a));
    // The category most of them have.
    const cats = new Map<string | null, number>();
    for (const t of g.items) cats.set(t.categoryId, (cats.get(t.categoryId) ?? 0) + 1);
    const categoryId = [...cats].sort((a, b) => b[1] - a[1])[0][0];
    return {
      payee,
      name: nameOf(newest),
      categoryId,
      count: g.items.length,
      totalCents: total,
      averageCents: Math.round(total / g.items.length),
      perMonthCents: per(total, Math.max(1, months)),
    };
  })
    .sort((a, b) => b.totalCents - a.totalCents)
    .slice(0, MAX_FREQUENT);
}

// ------------------------------------------------------------------ issues

/** Without accents ("Café" = "Cafe"). */
const fold = (s: string) => s.normalize("NFD").replace(/\p{M}/gu, "");

/** Whether two transactions may be the same booking entered twice: same amount, at most
 *  DUPLICATE_DAYS apart, the same payee (or one without text, on the same day), and not two rows
 *  a bank or a CSV file gave for the same account (those tell identical bookings apart). */
function maybeDuplicate(a: TransactionRow, b: TransactionRow): boolean {
  if (a.amount_cents !== b.amount_cents) return false;
  if (Math.abs(diffDays(a.day, b.day)) > DUPLICATE_DAYS) return false;
  // Two of one account and origin: a bank's or a file's rows are bookings of their own, typed
  // ones only count when typed for the same day.
  if (a.account_id === b.account_id && a.source === b.source && (a.source !== "manual" || a.day !== b.day)) {
    return false;
  }
  const ka = fold(similarKey(a)), kb = fold(similarKey(b));
  if (ka && ka === kb) return true;
  const ma = fold(merchantOf(a)), mb = fold(merchantOf(b));
  if (ma && ma === mb) return true;
  return a.day === b.day && (!ka || !kb);
}

/** Likely duplicates among the rows (not transfer legs or split bookings / parts): one to one,
 *  closest days first. */
export function findDuplicates(rows: TransactionRow[]): [TransactionRow, TransactionRow][] {
  const byAmount = new Map<number, TransactionRow[]>();
  for (const t of rows) byAmount.set(t.amount_cents, [...(byAmount.get(t.amount_cents) ?? []), t]);
  const candidates: { a: TransactionRow; b: TransactionRow; gap: number }[] = [];
  for (const same of byAmount.values()) {
    if (same.length < 2 || same.length > 200) continue; // 200 coffees for 3.20 € aren't duplicates
    for (let i = 0; i < same.length; i++) {
      for (let j = i + 1; j < same.length; j++) {
        if (maybeDuplicate(same[i], same[j])) {
          candidates.push({ a: same[i], b: same[j], gap: Math.abs(diffDays(same[i].day, same[j].day)) });
        }
      }
    }
  }
  candidates.sort((x, y) => x.gap - y.gap || y.a.day.localeCompare(x.a.day));
  const used = new Set<string>();
  const out: [TransactionRow, TransactionRow][] = [];
  for (const { a, b } of candidates) {
    if (used.has(a.id) || used.has(b.id)) continue;
    used.add(a.id);
    used.add(b.id);
    // The older one first (by day, then id), so the key doesn't change.
    out.push(a.day < b.day || (a.day === b.day && a.id < b.id) ? [a, b] : [b, a]);
  }
  return out;
}

/** The usual category per payee: of at least USUAL_MIN categorized transactions, the one at least
 *  USUAL_SHARE of them have. */
function usualCategories(rows: TransactionRow[]): Map<string, string> {
  const counts = new Map<string, Map<string, number>>();
  for (const t of rows) {
    const key = similarKey(t);
    if (!key || !t.category_id) continue;
    const m = counts.get(key) ?? new Map<string, number>();
    m.set(t.category_id, (m.get(t.category_id) ?? 0) + 1);
    counts.set(key, m);
  }
  const out = new Map<string, string>();
  for (const [key, m] of counts) {
    const total = [...m.values()].reduce((a, b) => a + b, 0);
    const [top, n] = [...m].sort((a, b) => b[1] - a[1])[0];
    if (total >= USUAL_MIN && n / total >= USUAL_SHARE) out.set(key, top);
  }
  return out;
}

// ------------------------------------------------------------------ dismissals

export function listDismissals(db: Db, familyId: string): Set<string> {
  return new Set(
    db.select({ key: finInsightDismissals.key }).from(finInsightDismissals)
      .where(eq(finInsightDismissals.familyId, familyId)).all().map((r) => r.key),
  );
}

export function dismissInsight(db: Db, familyId: string, key: string, userId: string | null, now: Date) {
  db.insert(finInsightDismissals)
    .values({ familyId, key, createdById: userId, createdAt: now })
    .onConflictDoNothing()
    .run();
}

export function restoreInsight(db: Db, familyId: string, key: string) {
  db.delete(finInsightDismissals)
    .where(and(eq(finInsightDismissals.familyId, familyId), eq(finInsightDismissals.key, key)))
    .run();
}

/** Whether a key names a known check ("duplicate:…", "recurring:…"). */
export function validInsightKey(v: unknown): v is string {
  if (typeof v !== "string" || v.length > 300) return false;
  const i = v.indexOf(":");
  return i > 0 && i < v.length - 1 && (INSIGHT_KINDS as readonly string[]).includes(v.slice(0, i));
}

// ------------------------------------------------------------------ all together

/**
 * The insights of the period (all time without from / to). The changes compare the period's
 * months (up to today) with the BASELINE_MONTHS completed months before it (as far as there are
 * transactions); regular payments are found up to `today`, whatever the period; issues are those
 * of the period's transactions.
 */
export async function buildInsights(
  db: Db,
  store: Store,
  familyId: string,
  { from, to, today }: { from?: string; to?: string; today: string },
): Promise<Insights> {
  const [settings, all, categories, accounts, suggestions] = await Promise.all([
    store.getFinanceSettings(familyId),
    store.listTransactions(familyId),
    store.listCategories(familyId),
    listAccounts(store, familyId),
    transferPairs(store, familyId, from, to),
  ]);
  const dismissed = listDismissals(db, familyId);
  let hidden = 0;
  const shown = (key: string) => {
    if (!dismissed.has(key)) return true;
    hidden++;
    return false;
  };
  const links: Links = await loadLinks(store, familyId, all);
  const items = netItems(all, links);
  const first = all.length ? all.reduce((d, t) => (t.day < d ? t.day : d), all[0].day) : null;

  // The period's months, up to today (a running month counts as one, "so far").
  const start = from ?? first ?? today;
  const end = to && to < today ? to : today;
  const months = end >= start ? monthsBetween(monthOf(start), monthOf(end)) : 0;
  const partial = !to || to > today;

  // Changes: only with a start, against the completed months before it.
  let baseline: Insights["baseline"] = null;
  let changes: Change[] = [];
  if (from && first && months > 0) {
    const baseTo = addMonths(monthOf(from), -1);
    let baseFrom = addMonths(baseTo, -(BASELINE_MONTHS - 1));
    if (monthOf(first) > baseFrom) baseFrom = monthOf(first);
    const n = monthsBetween(baseFrom, baseTo);
    if (n > 0) {
      baseline = { from: `${baseFrom}-01`, to: lastDayOf(baseTo), months: n };
      changes = spendingChanges(items, { from, to: end, months }, baseline);
    }
  }

  const recurring = recurringPayments(items, today).filter((r) => shown(r.key));
  const periodItems = items.filter((t) => inRange(t.day, from, to));
  const regular = new Set(recurring.filter((r) => r.status !== "stopped").map((r) => r.payee));
  const frequent = frequentSmall(periodItems, months, regular);

  let uncategorized = { count: 0, incomeCents: 0, expenseCents: 0 };
  for (const t of periodItems) {
    if (t.categoryId) continue;
    uncategorized = {
      count: uncategorized.count + 1,
      incomeCents: uncategorized.incomeCents + Math.max(0, t.amountCents),
      expenseCents: uncategorized.expenseCents + Math.max(0, -t.amountCents),
    };
  }

  // Issues among the period's transactions that aren't a transfer leg or in a split.
  const tree = categoryTree(categories);
  const linked = (t: TransactionRow) => !!groupOf(t, links.groups) || !!t.split_of || links.splits.has(t.id);
  const plain = all.filter((t) => !linked(t));
  const periodRows = plain.filter((t) => inRange(t.day, from, to));
  const pub = (t: TransactionRow) => publicTransaction(t, links);
  const issues: Issue[] = [];

  for (const [a, b] of findDuplicates(periodRows)) {
    const key = `duplicate:${a.id},${b.id}`;
    if (shown(key)) issues.push({ key, kind: "duplicate", day: b.day, transactions: [pub(a), pub(b)] });
  }

  // Transfers without their other leg: text that names one (or another of the family's accounts),
  // on an account, with another account to pair it with, and not among the suggested pairs.
  if (accounts.length >= 2) {
    const paired = new Set(suggestions.flatMap((p) => [p.out.id, p.in.id]));
    const names = accounts.filter((a) => a.name.trim().length >= 4)
      .map((a) => ({ id: a.id, name: a.name.trim().toLowerCase() }));
    for (const t of periodRows) {
      if (!t.account_id || paired.has(t.id)) continue;
      const text = `${t.payee} ${t.description}`;
      const lower = text.toLowerCase();
      if (!TRANSFER_RE.test(text) && !names.some((n) => n.id !== t.account_id && lower.includes(n.name))) continue;
      const key = `unpaired:${t.id}`;
      if (shown(key)) issues.push({ key, kind: "unpaired", day: t.day, transactions: [pub(t)] });
    }
  }

  // Unusual amounts: against the payee's earlier expenses.
  const history = new Map<string, TransactionRow[]>();
  for (const t of [...plain].sort((a, b) => a.day.localeCompare(b.day))) {
    if (t.amount_cents >= 0) continue;
    const key = similarKey(t);
    if (!key) continue;
    const earlier = history.get(key) ?? [];
    if (earlier.length >= AMOUNT_MIN && inRange(t.day, from, to)) {
      const usual = median(earlier.map((e) => -e.amount_cents));
      const cents = -t.amount_cents;
      if (cents >= usual * AMOUNT_FACTOR && cents - usual >= AMOUNT_MIN_CENTS) {
        const k = `amount:${t.id}`;
        if (shown(k)) issues.push({ key: k, kind: "amount", day: t.day, transactions: [pub(t)], usualCents: usual });
      }
    }
    earlier.push(t);
    history.set(key, earlier);
  }

  // Unusual categories: not the payee's usual one, nor above or below it in the tree.
  const usual = usualCategories(plain);
  for (const t of periodRows) {
    const key = similarKey(t);
    const u = key ? usual.get(key) : undefined;
    if (!u || !t.category_id || t.category_id === u || !tree.byId.has(u)) continue;
    if (tree.subtree(u).has(t.category_id) || (tree.byId.has(t.category_id) && tree.subtree(t.category_id).has(u))) continue;
    const k = `category:${t.id}`;
    if (shown(k)) issues.push({ key: k, kind: "category", day: t.day, transactions: [pub(t)], usualCategoryId: u });
  }

  const order: Record<Issue["kind"], number> = { duplicate: 0, unpaired: 1, amount: 2, category: 3 };
  issues.sort((a, b) => order[a.kind] - order[b.kind] || b.day.localeCompare(a.day));

  return {
    currency: settings?.currency ?? "EUR",
    from: from ?? null,
    to: to ?? null,
    today,
    partial,
    baseline,
    months,
    changes,
    recurring,
    recurringYearlyCents: recurring.filter((r) => r.status !== "stopped").reduce((s, r) => s + r.yearlyCents, 0),
    frequent,
    issues: issues.slice(0, MAX_ISSUES),
    uncategorized,
    transferSuggestions: suggestions.length,
    balanceDrift: accounts.flatMap((a) =>
      a.bank?.balanceCents != null && a.bank.balanceCents !== a.balanceCents
        ? [{ accountId: a.id, bankCents: a.bank.balanceCents, ohanaCents: a.balanceCents, at: a.bank.balanceAt ?? null }]
        : []
    ),
    dismissed: hidden,
  };
}
