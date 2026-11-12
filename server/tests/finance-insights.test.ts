// The finance overview's insights (lib/finance/insights.ts): the pure checks, the routes
// (GET /finance/insights, /finance/payees, ?payee=, dismissals) and the assistant's tools.
/* eslint-disable @typescript-eslint/no-explicit-any */

import { afterEach, describe, expect, it } from "vitest";
import type { NetOptions } from "@/lib/assistant/net";
import { runTool, type ToolContext, TOOLS } from "@/lib/assistant/tools";
import { addDays } from "@/lib/calendar/dates";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import type { NetItem } from "@/lib/finance/finance";
import {
  findDuplicates,
  frequentSmall,
  monthsBetween,
  recurringPayments,
  spendingChanges,
  validInsightKey,
} from "@/lib/finance/insights";
import { DrizzleFinanceStore, type TransactionRow } from "@/lib/finance/store";
import { type AssistantTest, assistantTest } from "@/lib/test/assistant";

const TODAY = "2026-11-12";

let current: AssistantTest[] = [];
afterEach(async () => {
  await Promise.all(current.map((t) => t.stop()));
  current = [];
});

const item = (day: string, amountCents: number, payee: string, categoryId: string | null = null): NetItem => ({
  day,
  amountCents,
  categoryId,
  accountId: "checking",
  payee,
  description: "",
});

/** The day of `month` (YYYY-MM) shifted by n months. */
function monthDay(month: string, n: number, day = "05"): string {
  const [y, m] = month.split("-").map(Number);
  const i = y * 12 + m - 1 + n;
  return `${Math.floor(i / 12)}-${String((i % 12) + 1).padStart(2, "0")}-${day}`;
}

let ids = 0;
const row = (over: Partial<TransactionRow>): TransactionRow => ({
  family_id: "f",
  id: `00000000-0000-4000-8000-${String(++ids).padStart(12, "0")}`,
  day: "2026-11-01",
  amount_cents: -1000,
  payee: "",
  description: "",
  category_id: null,
  note: "",
  import_hash: null,
  source: "manual",
  account_id: "checking",
  transfer_id: null,
  split_of: null,
  created_at: "2026-11-01T00:00:00.000Z",
  ...over,
});

describe("recurring payments", () => {
  it("finds a monthly subscription with its price change", () => {
    const items = [
      ...Array.from({ length: 9 }, (_, i) => item(monthDay("2025-11", i), -1299, "NETFLIX.COM 1234")),
      ...Array.from({ length: 4 }, (_, i) => item(monthDay("2026-08", i), -1599, "Netflix.com")),
    ];
    const [r] = recurringPayments(items, TODAY);
    expect(r).toMatchObject({
      payee: "netflix com",
      interval: "month",
      count: 13,
      amountCents: 1599,
      yearlyCents: 1599 * 12,
      status: "active",
      change: { previousCents: 1299, since: "2026-08-05" },
      lastDay: "2026-11-05",
      key: "recurring:netflix_com:month",
    });
  });

  it("tells stopped, new and yearly ones, and leaves irregular shopping out", () => {
    const items = [
      ...Array.from({ length: 6 }, (_, i) => item(monthDay("2026-01", i, "03"), -3000, "FitX Gym")),
      ...Array.from({ length: 3 }, (_, i) => item(monthDay("2026-08", i, "20"), -999, "Spotify")),
      item("2024-12-01", -24000, "HUK Coburg"),
      item("2025-12-01", -24000, "HUK Coburg"),
      // Groceries every three or four days, never the same amount.
      ...Array.from({ length: 40 }, (_, i) => item(addDays("2026-07-01", Math.floor(i * 3.5)), -(4000 + i * 37), "REWE Markt")),
    ];
    const byPayee = Object.fromEntries(recurringPayments(items, TODAY).map((r) => [r.payee, r]));
    expect(Object.keys(byPayee).sort()).toEqual(["fitx gym", "huk coburg", "spotify"]);
    expect(byPayee["fitx gym"].status).toBe("stopped");
    expect(byPayee.spotify.status).toBe("new");
    expect(byPayee["huk coburg"]).toMatchObject({ interval: "year", status: "active", nextDay: "2026-12-01" });
  });

  it("keeps two payments of one payee with different amounts apart", () => {
    const items = Array.from({ length: 5 }, (_, i) => [
      item(monthDay("2026-06", i, "02"), -99, "Apple"),
      item(monthDay("2026-06", i, "15"), -999, "Apple"),
    ]).flat();
    expect(recurringPayments(items, TODAY).map((r) => r.amountCents).sort((a, b) => a - b)).toEqual([99, 999]);
  });
});

it("ranks the categories whose spending grew, with the payees behind it", () => {
  const baseline = { from: "2025-11-01", to: "2026-10-31", months: 12 };
  const period = { from: "2026-11-01", to: TODAY, months: 1 };
  const items = [
    ...Array.from({ length: 12 }, (_, i) => item(monthDay("2025-11", i, "10"), -5000, "Pizzeria Roma", "restaurants")),
    ...Array.from({ length: 6 }, (_, i) => item(`2026-11-0${i + 1}`, -3000, "Lieferando.de", "restaurants")),
    item("2026-11-02", -5000, "Pizzeria Roma", "restaurants"),
    // Steady groceries don't show; a little more isn't a change.
    ...Array.from({ length: 13 }, (_, i) => item(monthDay("2025-11", i, "08"), i === 12 ? -40500 : -40000, "Rewe", "groceries")),
  ];
  const changes = spendingChanges(items, period, baseline);
  expect(changes).toHaveLength(1);
  expect(changes[0]).toMatchObject({ categoryId: "restaurants", currentCents: 23000, usualCents: 5000, deltaCents: 18000 });
  expect(changes[0].payees).toEqual([
    { key: "lieferando de", name: "Lieferando.de", count: 6, currentCents: 18000, usualCents: 0, deltaCents: 18000 },
  ]);
});

it("finds small amounts that add up, but not the regular ones", () => {
  const items = [
    ...Array.from({ length: 9 }, (_, i) => item(`2026-11-0${i + 1}`, -320, "Bäckerei Schmidt", "groceries")),
    ...Array.from({ length: 5 }, (_, i) => item(`2026-11-0${i + 1}`, -999, "Spotify")),
    item("2026-11-03", -12000, "Bäckerei Schmidt"), // not small
  ];
  expect(frequentSmall(items, 1, new Set(["spotify"]))).toEqual([{
    payee: "bäckerei schmidt",
    name: "Bäckerei Schmidt",
    categoryId: "groceries",
    count: 9,
    totalCents: 2880,
    averageCents: 320,
    perMonthCents: 2880,
  }]);
});

it("finds likely duplicates, but not what a bank or a CSV file gave twice for one account", () => {
  const bank = row({ day: "2026-11-03", amount_cents: -4210, payee: "SHELL 1234", source: "bank" });
  const typed = row({ day: "2026-11-04", amount_cents: -4210, payee: "Shell", account_id: null });
  const coffee1 = row({ day: "2026-11-05", amount_cents: -320, payee: "Café", source: "bank" });
  const coffee2 = row({ day: "2026-11-05", amount_cents: -320, payee: "Café", source: "bank" });
  const csv = row({ day: "2026-11-05", amount_cents: -320, payee: "Cafe", source: "csv" });
  const other = row({ day: "2026-11-04", amount_cents: -4210, payee: "Aral" });
  const pairs = findDuplicates([bank, typed, coffee1, coffee2, csv, other]);
  expect(pairs.map(([a, b]) => [a.payee, b.payee])).toEqual([["Café", "Cafe"], ["SHELL 1234", "Shell"]]);
});

it("knows its keys and months", () => {
  expect(validInsightKey("duplicate:a,b")).toBe(true);
  expect(validInsightKey("recurring:netflix:month")).toBe(true);
  expect(validInsightKey("nope:x")).toBe(false);
  expect(validInsightKey("duplicate:")).toBe(false);
  expect(monthsBetween("2025-11", "2026-10")).toBe(12);
  expect(monthsBetween("2026-11", "2026-10")).toBe(0);
});

// ------------------------------------------------------------------ the routes and tools

async function family() {
  const t = assistantTest({ worker: false });
  current.push(t);
  const call = async (method: string, path: string, body?: unknown) => {
    const res = await t.call(method, path, body);
    expect(res.status, JSON.stringify(res.data)).toBeLessThan(300);
    return res.data;
  };
  const ctx: ToolContext = {
    lang: "en",
    calendar: new DrizzleCalendarStore(t.db),
    finance: new DrizzleFinanceStore(t.db),
    db: t.db,
    familyId: t.familyId,
    today: TODAY,
    net: {} as NetOptions,
    search: null,
  };
  const tool = async (name: string, args: unknown) => {
    const res = await runTool(name, JSON.stringify(args), ctx, new Set(Object.keys(TOOLS)));
    return res as typeof res & { result: any };
  };
  const f = `${t.f}/finance`;
  await call("POST", `${f}/accounts`, { name: "Checking", color: "#3b82f6" });
  await call("POST", `${f}/accounts`, { name: "Tagesgeld", color: "#22c55e" });
  await call("POST", `${f}/categories/defaults`, { lang: "en" });
  await call("POST", `${f}/categories`, { name: "Restaurants", color: "#ef4444", kind: "expense" });
  const add = (ops: Record<string, unknown>[]) =>
    call("POST", `${f}/transactions`, { ops: ops.map((o) => ({ accountId: "checking", ...o })) });
  return { t, call, tool, f, add };
}

/** A year of the family's money, and this month's surprises. */
async function history(add: (ops: Record<string, unknown>[]) => Promise<unknown>) {
  const ops: Record<string, unknown>[] = [];
  for (let i = 0; i < 13; i++) {
    ops.push({ date: monthDay("2025-11", i), amountCents: i < 9 ? -1299 : -1599, payee: "NETFLIX.COM", categoryId: "leisure" });
    ops.push({ date: monthDay("2025-11", i, "10"), amountCents: -5000, payee: "Pizzeria Roma", categoryId: "restaurants" });
    for (const d of ["02", "12", "22"]) {
      ops.push({ date: monthDay("2025-11", i, d), amountCents: -5000 - i * 10, payee: "REWE Markt", categoryId: "groceries" });
    }
  }
  ops.push(
    ...Array.from({ length: 6 }, (_, i) => ({ date: `2026-11-0${i + 1}`, amountCents: -3000, payee: "Lieferando.de", categoryId: "restaurants" })),
    { date: "2026-11-03", amountCents: -4210, payee: "SHELL 1234", source: "bank", categoryId: "mobility" },
    { date: "2026-11-03", amountCents: -4210, payee: "Shell", accountId: null },
    { date: "2026-11-04", amountCents: -50000, payee: "Umbuchung auf Tagesgeld" },
    { date: "2026-11-07", amountCents: -35000, payee: "REWE Markt", categoryId: "groceries" },
    { date: "2026-11-08", amountCents: -6000, payee: "REWE Markt", categoryId: "leisure" },
  );
  await add(ops);
}

it("GET /finance/insights points out changes, regular payments and issues", async () => {
  const { call, f, add } = await family();
  await history(add);
  const res = await call("GET", `${f}/insights?from=2026-11-01&to=2026-11-30&today=${TODAY}`);
  expect(res).toMatchObject({ partial: true, months: 1, baseline: { from: "2025-11-01", to: "2026-10-31", months: 12 } });
  expect(res.changes.map((c: any) => c.categoryId)).toContain("restaurants");
  const restaurants = res.changes.find((c: any) => c.categoryId === "restaurants");
  expect(restaurants.payees[0].key).toBe("lieferando de");

  const netflix = res.recurring.find((r: any) => r.payee === "netflix com");
  expect(netflix).toMatchObject({ interval: "month", amountCents: 1599, change: { previousCents: 1299 } });

  // A pair of one day goes by id: its order is the uuids'.
  const kinds = res.issues.map((i: any) => [i.kind, i.transactions.map((t: any) => t.payee).sort().join(" + ")]);
  expect(kinds).toEqual([
    ["duplicate", "SHELL 1234 + Shell"],
    ["unpaired", "Umbuchung auf Tagesgeld"],
    ["amount", "REWE Markt"],
    ["category", "REWE Markt"],
  ]);
  expect(res.issues.find((i: any) => i.kind === "category").usualCategoryId).toBe("groceries");
  expect(res.uncategorized).toEqual({ count: 2, incomeCents: 0, expenseCents: 54210 });

  // "Looks fine" hides an issue until it is shown again.
  const key = res.issues[0].key;
  await call("POST", `${f}/insights/dismiss`, { key });
  const after = await call("GET", `${f}/insights?from=2026-11-01&to=2026-11-30&today=${TODAY}`);
  expect(after.issues.map((i: any) => i.key)).not.toContain(key);
  expect(after.dismissed).toBe(1);
  await call("DELETE", `${f}/insights/dismiss/${encodeURIComponent(key)}`);
  const again = await call("GET", `${f}/insights?from=2026-11-01&to=2026-11-30&today=${TODAY}`);
  expect(again.issues[0].key).toBe(key);
});

it("dismissals need an editor and a known key", async () => {
  const { t, f } = await family();
  expect((await t.call("POST", `${f}/insights/dismiss`, { key: "whatever" })).status).toBe(400);
  expect((await t.call("PUT", `${f}/insights`, {})).status).toBe(405);
});

it("GET /finance/payees and ?payee= drill into a category", async () => {
  const { call, f, add } = await family();
  await history(add);
  const res = await call("GET", `${f}/payees?from=2026-11-01&to=2026-11-30&category=restaurants&kind=expense`);
  expect(res.payees).toEqual([
    { key: "lieferando de", name: "Lieferando.de", count: 6, incomeCents: 0, expenseCents: 18000 },
    { key: "pizzeria roma", name: "Pizzeria Roma", count: 1, incomeCents: 0, expenseCents: 5000 },
  ]);
  expect(res.more).toBe(0);
  const list = await call("GET", `${f}/transactions?from=2026-11-01&to=2026-11-30&payee=lieferando%20de`);
  expect(list.total).toBe(6);
  expect(list.expenseCents).toBe(18000);
});

it("the assistant reads the insights in the currency and marks findings as fine with undo", async () => {
  const { call, tool, f, add } = await family();
  await history(add);
  const res = await tool("finance_insights", { from: "2026-11-01", to: "2026-11-30" });
  expect(res.ok, JSON.stringify(res.result)).toBe(true);
  expect(JSON.stringify(res.result)).not.toContain("Cents");
  expect(res.result.recurring.find((r: any) => r.payee === "netflix com").amount).toBe(15.99);
  expect(res.result.categoryPaths.restaurants).toBe("Restaurants");

  const key = res.result.issues[0].key;
  const dismissed = await tool("dismiss_finance_insights", { keys: [key] });
  expect(dismissed.ok).toBe(true);
  expect(dismissed.change?.undo).toEqual([{ method: "DELETE", path: `/finance/insights/dismiss/${encodeURIComponent(key)}` }]);
  const after = await call("GET", `${f}/insights?from=2026-11-01&to=2026-11-30&today=${TODAY}`);
  expect(after.dismissed).toBe(1);
  // The undo step works against the family API.
  await call("DELETE", `${f}/insights/dismiss/${encodeURIComponent(key)}`);
  expect((await tool("dismiss_finance_insights", { keys: ["bogus"] })).ok).toBe(false);

  const list = await tool("list_transactions", { payee: "lieferando de" });
  expect(list.result.total).toBe(6);
});
