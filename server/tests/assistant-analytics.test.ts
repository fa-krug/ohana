// family-planner's tests/analytics.test.ts: the calculator, and the tools that analyze
// transactions and count calendar days (against the family API on the in-memory database).
/* eslint-disable @typescript-eslint/no-explicit-any */

import { afterEach, expect, it } from "vitest";
import { isoWeek } from "@/lib/assistant/analytics";
import { calculate, type Value } from "@/lib/assistant/calc";
import type { NetOptions } from "@/lib/assistant/net";
import { runTool, type ToolContext, TOOLS } from "@/lib/assistant/tools";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { type AssistantTest, assistantTest } from "@/lib/test/assistant";

let current: AssistantTest[] = [];
afterEach(async () => {
  await Promise.all(current.map((t) => t.stop()));
  current = [];
});

// Deno's asserts, as the ported tests use them.
function assert(v: unknown, msg?: string): asserts v {
  expect(!!v, msg).toBe(true);
}
const assertEquals = (a: unknown, b: unknown, msg?: string) => expect(a, msg).toEqual(b);
const assertMatch = (a: string, re: RegExp) => expect(a).toMatch(re);
const assertAlmostEquals = (a: number, b: number, eps = 1e-7) => expect(Math.abs(a - b)).toBeLessThanOrEqual(eps);

/** The value of one expression; fails the test on an error. */
function calc(expression: string, vars?: Record<string, unknown>): Value {
  const [r] = calculate([expression], vars);
  assert(r.error === undefined, `${expression}: ${r.error}`);
  return r.value!;
}

function calcError(expression: string): string {
  const [r] = calculate([expression]);
  assert(r.error !== undefined, `${expression} should fail`);
  return r.error!;
}

it("calculates arithmetic with the usual precedence, without float noise", () => {
  assertEquals(calc("0.1 + 0.2"), 0.3);
  assertEquals(calc("2 + 3 * 4"), 14);
  assertEquals(calc("(2 + 3) * 4"), 20);
  assertEquals(calc("2 ^ 3 ^ 2"), 512);
  assertEquals(calc("2 ** 10"), 1024);
  assertEquals(calc("-2 ^ 2"), -4);
  assertEquals(calc("2 ^ -1"), 0.5);
  assertEquals(calc("7 % 3"), 1);
  assertEquals(calc("1.5e3 / 4"), 375);
  assertEquals(calc("round(2.345, 2)"), 2.35);
  assertEquals(calc("round(-2.5)"), -3);
  assertEquals(calc("log(1000)"), 3);
  assertEquals(calc("log(8, 2)"), 3);
  assertEquals(calc("round(pi, 4)"), 3.1416);
  assertEquals(calc("SQRT(16)"), 4);
});

it("calculates with lists, statistics and trends", () => {
  assertEquals(calc("[1, 2, 3] * 2"), [2, 4, 6]);
  assertEquals(calc("[1, 2, 3] + [10, 20, 30]"), [11, 22, 33]);
  assertEquals(calc("sum([1, 2], 3, [4])"), 10);
  assertEquals(calc("avg(x)", { x: [2, 4, 9] }), 5);
  assertEquals(calc("median([3, 1, 2, 10])"), 2.5);
  assertEquals(calc("min([4, -1, 7])"), -1);
  assertEquals(calc("max(4, -1, 7)"), 7);
  assertEquals(calc("count([5, 5, 5])"), 3);
  assertEquals(calc("stddevp([2, 4, 4, 4, 5, 5, 7, 9])"), 2);
  assertAlmostEquals(calc("stddev([2, 4, 4, 4, 5, 5, 7, 9])") as number, 2.13809, 1e-5);
  assertEquals(calc("percentile([1, 2, 3, 4, 5], 25)"), 2);
  assertEquals(calc("cumsum([1, 2, 3])"), [1, 3, 6]);
  assertEquals(calc("diff([1, 4, 9])"), [3, 5]);
  assertEquals(calc("growth([100, 110, 99])"), [0.1, -0.1]);
  assertEquals(calc("seq(1, 5)"), [1, 2, 3, 4, 5]);
  assertEquals(calc("seq(0, 1, 0.25)"), [0, 0.25, 0.5, 0.75, 1]);
  assertEquals(calc("sort([3, 1, 2])"), [1, 2, 3]);
  assertEquals(calc("slope([10, 20, 30])"), 10);
  assertEquals(calc("intercept([10, 20, 30])"), 10);
  assertEquals(calc("forecast([10, 20, 30], 1)"), 40);
  assertEquals(calc("forecast([10, 20, 30], [1, 2])"), [40, 50]);
  assertEquals(calc("slope([3, 5, 7], [1, 2, 3])"), 2);
  assertEquals(calc("correl([1, 2, 3], [2, 4, 6])"), 1);
});

it("calculates loans and savings like a spreadsheet", () => {
  // 200,000 over 30 years at 6 % a year: 1,199.10 a month (paid out, so negative).
  const [rate, payment] = calculate(["rate = 0.06 / 12", "round(pmt(rate, 360, 200000), 2)"]);
  assertEquals([rate.name, rate.value], ["rate", 0.005]);
  assertEquals(payment.value, -1199.1);
  assertAlmostEquals(calc("fv(0.05, 10, -100)") as number, 1257.789, 1e-3);
  assertAlmostEquals(calc("pv(0.05, 10, -100)") as number, 772.173, 1e-3);
  assertAlmostEquals(calc("nper(0.01, -100, 1000)") as number, 10.5886, 1e-4);
  assertAlmostEquals(calc("npv(0.1, [100, 100])") as number, 173.5537, 1e-4);
  assertAlmostEquals(calc("irr([-1000, 300, 400, 500])") as number, 0.0889634, 1e-6);
  assertAlmostEquals(calc("cagr(100, 200, 10)") as number, 0.0717735, 1e-6);
  assertEquals(calc("pmt(0, 10, 1000)"), -100);
});

it("calculation errors are reported per expression", () => {
  assertMatch(calcError("1 / 0"), /Division by zero/);
  assertMatch(calcError("foo(1)"), /Unknown function "foo"/);
  assertMatch(calcError("x + 1"), /Unknown name "x"/);
  assertMatch(calcError("constructor(1)"), /Unknown function "constructor"/);
  assertMatch(calcError("toString + 1"), /Unknown name "toString"/);
  assertMatch(calcError("2 +"), /ends too early/);
  assertMatch(calcError("(1 + 2"), /Expected "\)"/);
  assertMatch(calcError("2 € 3"), /Unexpected "€"/);
  assertMatch(calcError("[1, 2] + [1, 2, 3]"), /different lengths/);
  assertMatch(calcError("sqrt(-1)"), /not a finite number/);
  assertMatch(calcError("avg([])"), /at least one number/);
  assertMatch(calcError("seq(1, 1000000)"), /at most 10000/);
  assertMatch(calcError("(".repeat(100) + "1" + ")".repeat(100)), /nested too deeply/);
  // The other expressions still run.
  const results = calculate(["a = 2", "a / 0", "a * 3"]);
  assertEquals(results.map((r) => r.value ?? r.error), [2, "Division by zero", 6]);
});

it("ISO weeks start on Monday and belong to the year of their Thursday", () => {
  assertEquals(isoWeek("2026-01-01"), "2026-W01");
  assertEquals(isoWeek("2025-12-29"), "2026-W01");
  assertEquals(isoWeek("2027-01-03"), "2026-W53");
  assertEquals(isoWeek("2026-03-10"), "2026-W11");
});

/** A family with the default types and categories (as its editor), and its tools. */
async function family() {
  const t = assistantTest({ worker: false });
  current.push(t);
  const call = async (method: string, path: string, body?: unknown) => {
    const res = await t.call(method, path, body);
    assert(res.status < 300, JSON.stringify(res.data));
    return res.data;
  };
  const ctx: ToolContext = {
    lang: "en",
    calendar: new DrizzleCalendarStore(t.db),
    finance: new DrizzleFinanceStore(t.db),
    db: t.db,
    familyId: t.familyId,
    net: {} as NetOptions,
    search: null,
  };
  const tool = async (name: string, args: unknown) => {
    const res = await runTool(name, JSON.stringify(args), ctx, new Set(Object.keys(TOOLS)));
    return res as typeof res & { result: any };
  };
  return { call, tool, f: t.f };
}

it("the calculate tool evaluates expressions with variables", async () => {
  const { tool } = await family();
  const res = await tool("calculate", {
    expressions: ["total = sum(spent)", "total / count(spent)", "nope("],
    vars: { spent: [412.5, 380, 455.25] },
  });
  assert(res.ok);
  assertEquals(res.result.results.map((r: any) => r.value ?? "error"), [
    1247.75,
    415.916666667,
    "error",
  ]);
  const one = await tool("calculate", { expressions: ["19% of 250"] });
  assertEquals(one.ok, true);
  assertMatch(one.result.results[0].error, /Unknown name "of"/);
  assertEquals((await tool("calculate", { expression: "6 * 7" })).summary, "6 * 7 = 42");
  const bad = await tool("calculate", { expressions: ["1"], vars: { x: "a lot" } });
  assertEquals(bad.ok, false);
  assertMatch(bad.result.error, /must be a number or a list/);
});

it("analyzes transactions per month, category and payee, counted like the totals", async () => {
  const { call, tool, f } = await family();
  await call("POST", `${f}/finance/accounts`, { name: "Checking", color: "#3b82f6" });
  await call("POST", `${f}/finance/accounts`, { name: "Savings", color: "#22c55e" });
  const { added } = await call("POST", `${f}/finance/transactions`, {
    ops: [
      { date: "2026-01-05", amountCents: 300000, payee: "ACME Corp", categoryId: "salary" },
      { date: "2026-01-10", amountCents: -5000, payee: "REWE Markt 1234", categoryId: "groceries" },
      { date: "2026-01-20", amountCents: -7000, payee: "Rewe Markt 99", categoryId: "groceries" },
      { date: "2026-03-03", amountCents: -3000, payee: "Lidl", categoryId: "groceries" },
      { date: "2026-03-15", amountCents: -50000, payee: "Transfer", accountId: "checking" },
      { date: "2026-03-15", amountCents: 50000, payee: "Transfer", accountId: "savings" },
    ],
  });
  // Moving money to savings counts nothing.
  await call("POST", `${f}/finance/transactions`, {
    ops: [{ action: "link", ids: added.slice(4) }],
  });

  const months = await tool("analyze_transactions", { from: "2026-01-01", to: "2026-03-31" });
  assert(months.ok, JSON.stringify(months.result));
  assertEquals(months.result.groupBy, ["month"]);
  assertEquals(
    months.result.groups.map((g: any) => [g.month, g.count, g.incomeCents, g.expenseCents]),
    [["2026-01", 3, 300000, 12000], ["2026-02", 0, 0, 0], ["2026-03", 1, 0, 3000]],
  );
  assertEquals(months.result.total, {
    count: 4,
    incomeCents: 300000,
    expenseCents: 15000,
    netCents: 285000,
  });
  // The average month, empty February included.
  assertEquals(months.result.perGroup.avgExpenseCents, 5000);
  assertEquals(months.result.perGroup.medianExpenseCents, 3000);

  const cats = await tool("analyze_transactions", {
    groupBy: ["category"],
    kind: "expense",
    stats: ["avg", "median", "min", "max", "stddev"],
  });
  assertEquals(cats.result.groups, [{
    category: "groceries",
    categoryName: "Groceries",
    count: 3,
    incomeCents: 0,
    expenseCents: 15000,
    netCents: -15000,
    avgCents: -5000,
    medianCents: -5000,
    minCents: -7000,
    maxCents: -3000,
    stddevCents: 2000,
  }]);

  // Spellings of one payee go together; largest first.
  const payees = await tool("analyze_transactions", { groupBy: ["payee"], kind: "expense" });
  assertEquals(
    payees.result.groups.map((g: any) => [g.payee.toLowerCase().slice(0, 10), g.expenseCents]),
    [["rewe markt", 12000], ["lidl", 3000]],
  );

  // Two dimensions, sorted by count, and a limit.
  const two = await tool("analyze_transactions", {
    groupBy: ["month", "kind"],
    sortBy: "count",
    limit: 1,
  });
  assertEquals(two.result.groupCount, 3);
  assertEquals(two.result.more, 2);
  assertEquals(two.result.groups[0].month, "2026-01");
  assertEquals(two.result.groups[0].kind, "expense");
  assert(!("perGroup" in two.result));

  const weekdays = await tool("analyze_transactions", { groupBy: "weekday", kind: "expense" });
  assertEquals(weekdays.result.groups.map((g: any) => g.weekday), ["Tue", "Sat"]);

  const bad = await tool("analyze_transactions", { groupBy: ["month", "payee", "kind"] });
  assertMatch(bad.result.error, /at most 2/);
  const unknown = await tool("analyze_transactions", { groupBy: ["color"] });
  assertMatch(unknown.result.error, /groupBy can only hold/);

  // Several analyses in one call: shared options, each its own filters; a bad one doesn't spoil
  // the others.
  const batch = await tool("analyze_transactions", {
    groupBy: ["category"],
    kind: "expense",
    queries: [
      { label: "January", from: "2026-01-01", to: "2026-01-31" },
      { label: "March", from: "2026-03-01", to: "2026-03-31", groupBy: ["payee"] },
      { groupBy: ["color"] },
    ],
  });
  assert(batch.ok, JSON.stringify(batch.result));
  const [jan, mar, broken] = batch.result.results;
  assertEquals(jan.label, "January");
  assertEquals(jan.groupBy, ["category"]);
  assertEquals(jan.groups.map((g: any) => [g.category, g.expenseCents]), [["groceries", 12000]]);
  assertEquals(mar.label, "March");
  assertEquals(mar.groups.map((g: any) => [g.payee, g.expenseCents]), [["Lidl", 3000]]);
  assertMatch(broken.error, /groupBy can only hold/);
  assert(!("label" in broken));

  const none = await tool("analyze_transactions", { queries: [] });
  assertMatch(none.result.error, /queries must be a list/);
  const many = await tool("analyze_transactions", { queries: Array(11).fill({}) });
  assertMatch(many.result.error, /queries must be a list/);
});

it("counts calendar days per type, month or weekday", async () => {
  const { call, tool, f } = await family();
  await call("POST", `${f}/entries`, {
    ops: [
      { action: "add", type: "vacation", from: "2026-08-03", to: "2026-08-14", skipWeekends: true },
      { action: "add", type: "holiday", dates: ["2026-08-05", "2026-12-25"] },
      { action: "add", type: "sick", dates: ["2026-02-02", "2026-02-07"] },
    ],
  });
  const year = { from: "2026-01-01", to: "2026-12-31" };

  const byType = await tool("analyze_calendar", year);
  assert(byType.ok, JSON.stringify(byType.result));
  assertEquals(byType.result.groups, [
    { type: "holiday", typeName: "Holiday", days: 2 },
    { type: "vacation", typeName: "Vacation", days: 10 },
    { type: "sick", typeName: "Sick", days: 2 },
  ]);
  assertEquals(byType.result.days, 13);

  // A vacation day on a public holiday costs nothing; Saturdays and Sundays don't count.
  const used = await tool("analyze_calendar", {
    ...year,
    types: ["Vacation", "sick"],
    skipDaysOff: true,
    weekdaysOnly: true,
  });
  assertEquals(used.result.groups.map((g: any) => [g.type, g.days]), [["vacation", 9], [
    "sick",
    1,
  ]]);

  const months = await tool("analyze_calendar", { ...year, groupBy: ["month"], types: ["sick"] });
  assertEquals(months.result.groups.length, 12);
  assertEquals(months.result.groups[1], { month: "2026-02", days: 2 });
  assertEquals(months.result.groups[7], { month: "2026-08", days: 0 });

  const both = await tool("analyze_calendar", { ...year, groupBy: ["type", "weekday"] });
  assertEquals(
    both.result.groups.filter((g: any) => g.type === "vacation").map((g: any) => g.days),
    [2, 2, 2, 2, 2],
  );

  assertMatch((await tool("analyze_calendar", { ...year, types: ["nope"] })).result.error, /nope/);
  const long = await tool("analyze_calendar", { from: "2000-01-01", to: "2026-12-31" });
  assertMatch(long.result.error, /ten years/);
});
