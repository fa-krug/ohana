// The finance part of family-planner's tests/api.test.ts, against Ohana's family API on the
// in-memory database (Drizzle store), signed in with API tokens. Clones and the memory store's
// snapshots aren't Ohana's (copyFinance is tested directly); the AI tools come with phase 3.

import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { familyMembers, finAccounts, finCategories, finSettings, finTransactions } from "@/lib/db/schema";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { handleFamily } from "@/lib/calendar/family-routes";
import { handleCalendar } from "@/lib/calendar/vacation";
import { copyFinance, handleFinance } from "@/lib/finance/finance";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { monthSummary } from "@/lib/finance/summary";
import { createFamily, deleteFamily } from "@/lib/families/manage";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const BASE = "http://ohana.test/api/v1";

type Res = { status: number; data: any; headers: Headers };
type Call = (method: string, path: string, body?: unknown) => Promise<Res>;

function setup() {
  const db = createTestDb();
  const handler = createFamilyApi([handleFamily, handleCalendar, handleFinance], {
    db,
    appUrl: "http://ohana.test",
    now: () => NOW,
  });
  const as =
    (token: string): Call =>
    async (method, path, body) => {
      const res = await handler(
        new Request(BASE + path, {
          method,
          headers: {
            authorization: `Bearer ${token}`,
            ...(body !== undefined ? { "content-type": "application/json" } : {}),
          },
          body: body !== undefined ? JSON.stringify(body) : undefined,
        }),
      );
      const text = await res.text();
      let data: any = text;
      try {
        data = JSON.parse(text);
      } catch {
        /* not JSON */
      }
      return { status: res.status, data, headers: res.headers };
    };
  const apiToken = (userId: string) => createToken(db, { userId, kind: "api" }, NOW).token;
  const owner = makeUser(db, { email: "owner@test", isAdmin: true });
  const call = as(apiToken(owner.id));
  let viewers = 0;
  const viewerOf = (familyId: string) => {
    const viewer = makeUser(db, { email: `viewer${++viewers}@test` });
    db.insert(familyMembers).values({ familyId, userId: viewer.id, role: "viewer", joinedAt: NOW }).run();
    return as(apiToken(viewer.id));
  };
  /** A new family of the owner, and `view`: a call as a viewer of it. */
  const newFamily = () => {
    const family = makeFamily(db, owner.id);
    return { id: family.id, view: viewerOf(family.id) };
  };
  const store = new DrizzleFinanceStore(db);
  return { db, call, owner, newFamily, store };
}

function financeFamily() {
  const t = setup();
  const s = t.newFamily();
  const f = `/families/${s.id}/finance`;
  return { ...t, s, f };
}

/** A family with two accounts, and helpers that add transactions (returning their ids), apply
 *  ops and list transactions. */
async function accountsFamily() {
  const t = financeFamily();
  const { call, f } = t;
  await call("POST", `${f}/accounts`, { name: "Checking", color: "#3b82f6", openingCents: 1000 });
  await call("POST", `${f}/accounts`, { name: "Savings", color: "#22c55e" });
  const add = async (...ops: Record<string, unknown>[]) => {
    const res = await call("POST", `${f}/transactions`, { ops });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    return res.data.added as string[];
  };
  const ops = async (...ops: Record<string, unknown>[]) => {
    const res = await call("POST", `${f}/transactions`, { ops });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    return res.data;
  };
  const list = async (query = "") => (await call("GET", `${f}/transactions${query ? "?" + query : ""}`)).data;
  return { ...t, add, ops, list };
}

describe("finance categories and settings", () => {
  it("new families get default finance categories", async () => {
    const { db, call, owner, f } = financeFamily();
    const res = await call("GET", f);
    expect(res.status).toBe(200);
    expect(res.data.currency).toBe("EUR");
    expect(res.data.categories[0]).toEqual({
      id: "salary",
      name: "Salary",
      color: "#22c55e",
      icon: "💼",
      kind: "income",
      position: 0,
      parentId: null,
    });
    expect(res.data.categories).toHaveLength(13);
    const de = createFamily(db, { name: "Krug", editorId: owner.id, lang: "de" }, NOW);
    const cats = (await call("GET", `/families/${de.id}/finance`)).data.categories;
    expect(cats.find((c: any) => c.id === "groceries").name).toBe("Lebensmittel");
  });

  it("manages finance categories and settings", async () => {
    const { call, store, s, f } = financeFamily();
    await store.deleteCategory(s.id, "groceries"); // like a family from before finances
    const add = await call("POST", `${f}/categories`, { name: "Pets", color: "#ff0000", icon: "🐶" });
    expect(add.status).toBe(201);
    expect(add.data.id).toBe("pets");
    expect(add.data.kind).toBe("expense");
    const patched = await call("PATCH", `${f}/categories/Pets`, { kind: "both", position: 99 });
    expect([patched.data.kind, patched.data.position]).toEqual(["both", 99]);
    expect((await call("POST", `${f}/categories`, { name: "X", color: "red" })).status).toBe(400);

    const defaults = await call("POST", `${f}/categories/defaults`, { lang: "en" });
    expect(defaults.data.some((c: any) => c.id === "groceries")).toBe(true);
    expect(defaults.data.filter((c: any) => c.id === "salary").length).toBe(1);

    const settings = await call("PATCH", `${f}/settings`, {
      currency: "CHF",
      csvMappings: [{ signature: "a;b", date: 0 }],
    });
    expect(settings.data.currency).toBe("CHF");
    expect(settings.data.csvMappings).toEqual([{ signature: "a;b", date: 0 }]);
    expect((await call("PATCH", `${f}/settings`, { currency: "euro" })).status).toBe(400);
    expect((await s.view("PATCH", `/families/${s.id}/finance/settings`, {})).status).toBe(403);

    expect((await call("DELETE", `${f}/categories/pets`)).status).toBe(200);
    expect((await call("DELETE", `${f}/categories/pets`)).status).toBe(404);
  });

  it("stores a statistic average to compare with", async () => {
    const { call, s, f } = financeFamily();
    expect((await call("GET", f)).data.benchmark).toBeNull();
    const set = await call("PATCH", `${f}/settings`, {
      benchmark: {
        label: " Destatis 2024 ",
        income: { lowCents: 420000, highCents: 620000 },
        expense: 380000, // a single value
        categories: [
          { categoryId: "Groceries", lowCents: 60000, highCents: 80000 },
          { categoryId: "salary", highCents: 1 }, // one end is enough
        ],
      },
    });
    expect(set.status, JSON.stringify(set.data)).toBe(200);
    expect(set.data.benchmark).toEqual({
      label: "Destatis 2024",
      income: { lowCents: 420000, highCents: 620000 },
      expense: { lowCents: 380000, highCents: 380000 },
      categories: [
        { categoryId: "groceries", lowCents: 60000, highCents: 80000 },
        { categoryId: "salary", lowCents: 1, highCents: 1 },
      ],
    });
    // Other settings leave it alone; a deleted category drops out of it.
    await call("PATCH", `${f}/settings`, { currency: "CHF" });
    await call("DELETE", `${f}/categories/salary`);
    expect((await call("GET", f)).data.benchmark.categories).toEqual([
      { categoryId: "groceries", lowCents: 60000, highCents: 80000 },
    ]);
    // Viewers see it, but can't change it.
    expect((await s.view("GET", `/families/${s.id}/finance`)).data.benchmark.label).toBe("Destatis 2024");
    expect((await s.view("PATCH", `/families/${s.id}/finance/settings`, { benchmark: null })).status).toBe(403);
    for (const bad of [
      { income: -1 },
      { expense: 1.5 },
      { income: { lowCents: 5, highCents: 4 } },
      { expense: "much" },
      { label: 3, income: 1 },
      { categories: [{ categoryId: "nope", cents: 1 }] },
      { categories: "groceries" },
      "x",
    ]) {
      const res = await call("PATCH", `${f}/settings`, { benchmark: bad });
      expect([400, 404], JSON.stringify(bad)).toContain(res.status);
    }
    // Without any amount (or null) it is gone.
    const empty = await call("PATCH", `${f}/settings`, { benchmark: { label: "Only a label" } });
    expect(empty.data.benchmark).toBeNull();
    await call("PATCH", `${f}/settings`, { benchmark: { income: 1 } });
    expect((await call("PATCH", `${f}/settings`, { benchmark: null })).data.benchmark).toBeNull();
  });

  it("nests finance categories to any depth", async () => {
    const { call, s, f, newFamily } = financeFamily();
    const food = (await call("POST", `${f}/categories`, { name: "Food", color: "#ff0000" })).data;
    expect(food.parentId).toBeNull();
    // Moving a category under another; a subcategory has its top-level category's kind.
    const moved = await call("PATCH", `${f}/categories/groceries`, { parentId: "Food" });
    expect([moved.data.parentId, moved.data.kind]).toEqual(["food", "expense"]);
    const bakery = await call("POST", `${f}/categories`, {
      name: "Bakery",
      color: "#00ff00",
      kind: "income",
      parentId: "food > GROCERIES",
    });
    expect([bakery.status, bakery.data.parentId, bakery.data.kind]).toEqual([201, "groceries", "expense"]);
    // Not into itself or one of its subcategories.
    for (const parentId of ["food", "bakery"]) {
      expect((await call("PATCH", `${f}/categories/food`, { parentId })).status).toBe(400);
    }
    // The top level's kind goes down the tree; a subcategory's can't be set.
    await call("PATCH", `${f}/categories/food`, { kind: "both" });
    await call("PATCH", `${f}/categories/bakery`, { kind: "income" });
    const kinds = async () =>
      Object.fromEntries((await call("GET", f)).data.categories.map((c: any) => [c.id, [c.parentId, c.kind]]));
    expect((await kinds()).bakery).toEqual(["groceries", "both"]);

    // A name that several categories have needs the path.
    await call("POST", `${f}/categories`, { name: "Other", color: "#000000", parentId: "food" });
    const ambiguous = await call("POST", `${f}/transactions`, {
      date: "2026-03-01",
      amountCents: -1,
      categoryId: "Other",
    });
    expect(ambiguous.status).toBe(400);
    expect(ambiguous.data.error).toMatch(/Food > Other/);

    const add = await call("POST", `${f}/transactions`, {
      ops: [
        { date: "2026-03-01", amountCents: -100, payee: "Market", categoryId: "Food" },
        { date: "2026-03-02", amountCents: -200, payee: "Super", categoryId: "Food > Groceries" },
        { date: "2026-03-03", amountCents: -400, payee: "Baker", categoryId: "bakery" },
        { date: "2026-03-04", amountCents: -800, payee: "Snacks", categoryId: "Food > Other" },
        { date: "2026-03-05", amountCents: -1600, payee: "Rent", categoryId: "housing" },
      ],
    });
    expect(add.status).toBe(200);
    // Filtering by a category includes its subcategories.
    const total = async (category: string) =>
      (await call("GET", `${f}/transactions?category=${encodeURIComponent(category)}`)).data.expenseCents;
    expect(await total("food")).toBe(1500);
    expect(await total("groceries")).toBe(600);
    expect(await total("Food > Groceries > Bakery")).toBe(400);

    // Deleting moves the subcategories and transactions to the parent.
    expect((await call("DELETE", `${f}/categories/groceries`)).status).toBe(200);
    expect((await kinds()).bakery).toEqual(["food", "both"]);
    const list = (await call("GET", `${f}/transactions?category=food`)).data.transactions;
    expect(list.find((t: any) => t.payee === "Super").categoryId).toBe("food");
    // A top-level one's subcategories become top-level ones, its transactions uncategorized.
    await call("DELETE", `${f}/categories/food`);
    expect((await kinds()).bakery).toEqual([null, "both"]);
    expect(await total("none")).toBe(300);

    // Export and import keep the tree; a loop is refused.
    await call("PATCH", `${f}/categories/bakery`, { parentId: "housing" });
    const file = (await call("GET", `/families/${s.id}/export`)).data;
    const target = newFamily();
    expect((await call("POST", `/families/${target.id}/import`, file)).status).toBe(200);
    const imported = (await call("GET", `/families/${target.id}/finance`)).data.categories;
    expect(imported.find((c: any) => c.id === "bakery").parentId).toBe("housing");
    const loop = file.finance.categories.map((c: any) => (c.id === "housing" ? { ...c, parentId: "bakery" } : c));
    const bad = { ...file, finance: { ...file.finance, categories: loop } };
    expect((await call("POST", `/families/${target.id}/import`, bad)).status).toBe(400);
  });

  it("imports a subcategory listed before its parent", async () => {
    const { call, s, f, newFamily } = financeFamily();
    await call("POST", `${f}/categories`, { name: "Bakery", color: "#00ff00", parentId: "groceries" });
    const file = (await call("GET", `/families/${s.id}/export`)).data;
    const categories = [...file.finance.categories].reverse();
    const target = newFamily();
    const res = await call("POST", `/families/${target.id}/import`, { ...file, finance: { ...file.finance, categories } });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    const imported = (await call("GET", `/families/${target.id}/finance`)).data.categories;
    expect(imported.find((c: any) => c.id === "bakery").parentId).toBe("groceries");
  });
});

describe("finance transactions", () => {
  it("adds, updates and deletes transactions with undo ops", async () => {
    const { call, f } = financeFamily();
    const add = await call("POST", `${f}/transactions`, {
      ops: [
        { date: "2026-03-01", amountCents: 250000, payee: "Employer", categoryId: "salary" },
        { date: "2026-03-02", amountCents: -4599, payee: "Supermarket", categoryId: "Groceries" },
        { date: "2026-04-10", amountCents: -120000, payee: "Landlord", categoryId: "housing" },
      ],
    });
    expect(add.status).toBe(200);
    expect(add.data.added.length).toBe(3);
    const [salary, groceries] = add.data.added;

    const list = await call("GET", `${f}/transactions?from=2026-03-01&to=2026-03-31`);
    expect(list.data.total).toBe(2);
    expect(list.data.incomeCents).toBe(250000);
    expect(list.data.expenseCents).toBe(4599);
    // Newest first.
    expect(list.data.transactions.map((t: any) => t.payee)).toEqual(["Supermarket", "Employer"]);
    expect(list.data.transactions[0].categoryId).toBe("groceries");

    const update = await call("POST", `${f}/transactions`, {
      action: "update",
      id: groceries,
      amountCents: -5000,
      categoryId: null,
    });
    expect(update.status).toBe(200);
    const none = await call("GET", `${f}/transactions?category=none`);
    expect(none.data.transactions.map((t: any) => t.amountCents)).toEqual([-5000]);

    // The inverse ops put it back.
    await call("POST", `${f}/transactions`, { ops: update.data.inverse });
    const back = (await call("GET", `${f}/transactions?q=supermarket`)).data.transactions[0];
    expect([back.amountCents, back.categoryId]).toEqual([-4599, "groceries"]);

    const del = await call("POST", `${f}/transactions`, { action: "delete", ids: [salary] });
    expect(del.data.changed).toBe(1);
    expect((await call("GET", `${f}/transactions?kind=income`)).data.total).toBe(0);
    await call("POST", `${f}/transactions`, { ops: del.data.inverse });
    const restored = (await call("GET", `${f}/transactions?kind=income`)).data.transactions;
    expect(restored.map((t: any) => [t.id, t.payee])).toEqual([[salary, "Employer"]]);

    // Undoing an add deletes it.
    await call("POST", `${f}/transactions`, { ops: add.data.inverse });
    expect((await call("GET", `${f}/transactions`)).data.total).toBe(0);
  });

  it("deletes all finance data", async () => {
    const { call, s, f, newFamily } = financeFamily();
    await call("POST", `${f}/transactions`, {
      ops: [{ date: "2026-03-01", amountCents: 250000, payee: "Employer", categoryId: "salary" }],
    });
    await call("PATCH", `${f}/settings`, { currency: "CHF", csvMappings: [{ signature: "a;b" }] });
    await call("POST", `${f}/accounts`, { name: "Checking", color: "#3b82f6" });
    const other = newFamily();
    const o = `/families/${other.id}/finance`;
    await call("POST", `${o}/transactions`, { date: "2026-03-01", amountCents: 1 });
    await call("POST", `${o}/accounts`, { name: "Cash", color: "#22c55e" });

    // Only editors may.
    expect((await s.view("DELETE", `/families/${s.id}/finance`)).status).toBe(403);
    const res = await call("DELETE", f);
    expect(res.status).toBe(200);
    expect(res.data).toEqual({
      currency: "EUR",
      csvMappings: [],
      benchmark: null,
      accounts: [],
      categories: [],
      groceriesCategoryId: null,
    });
    expect((await call("GET", `${f}/transactions`)).data.total).toBe(0);
    // Other families keep theirs.
    expect((await call("GET", `${o}/transactions`)).data.total).toBe(1);
    expect((await call("GET", o)).data.categories.length).toBeGreaterThan(0);
    expect((await call("GET", o)).data.accounts.length).toBe(1);
  });

  it("validates transaction ops", async () => {
    const { call, s, f } = financeFamily();
    const status = async (body: unknown) => (await call("POST", `${f}/transactions`, body)).status;
    expect(await status({ date: "2026-02-30", amountCents: 1 })).toBe(400);
    expect(await status({ date: "2026-02-01", amountCents: 1.5 })).toBe(400);
    expect(await status({ date: "2026-02-01", amountCents: 1, categoryId: "nope" })).toBe(404);
    expect(await status({ date: "2026-02-01", amountCents: 1, payee: "x".repeat(201) })).toBe(400);
    expect(await status({ action: "update", id: "not-a-uuid" })).toBe(400);
    expect(await status({ action: "update", id: crypto.randomUUID(), payee: "x" })).toBe(404);
    expect(await status({ action: "fly" })).toBe(400);
    // Viewers read, editors write.
    expect((await s.view("GET", `/families/${s.id}/finance/transactions`)).status).toBe(200);
    expect((await s.view("POST", `/families/${s.id}/finance/transactions`, { date: "2026-02-01", amountCents: 1 })).status).toBe(
      403,
    );
  });

  it("imports statement rows once, keeping identical rows apart", async () => {
    const { call, f } = financeFamily();
    const rows = [
      { date: "2026-05-02", amountCents: -350, payee: "Café", description: "Coffee" },
      { date: "2026-05-02", amountCents: -350, payee: "Café", description: "Coffee" },
      { date: "2026-05-03", amountCents: 100000, payee: "Employer", categoryId: "salary" },
    ];
    const dry = await call("POST", `${f}/import`, { rows, dryRun: true });
    expect([dry.data.added, dry.data.duplicates]).toEqual([0, []]);
    expect((await call("GET", `${f}/transactions`)).data.total).toBe(0);

    const first = await call("POST", `${f}/import`, { rows });
    expect([first.data.added, first.data.duplicates]).toEqual([3, []]);
    // Same statement again: nothing new.
    const again = await call("POST", `${f}/import`, { rows });
    expect([again.data.added, again.data.duplicates]).toEqual([0, [0, 1, 2]]);
    // A longer statement with a third coffee: only that one is new.
    const more = await call("POST", `${f}/import`, { rows: [...rows, rows[0]] });
    expect([more.data.added, more.data.duplicates]).toEqual([1, [0, 1, 2]]);
    const list = (await call("GET", `${f}/transactions`)).data;
    expect(list.total).toBe(4);
    expect(list.transactions.every((t: any) => t.imported)).toBe(true);
    expect((await call("POST", `${f}/import`, { rows: [{ date: "x" }] })).status).toBe(400);
  });

  it("summarizes income and expenses per month and category", async () => {
    const { call, f } = financeFamily();
    await call("POST", `${f}/transactions`, {
      ops: [
        { date: "2026-01-31", amountCents: 300000, categoryId: "salary" },
        { date: "2026-01-15", amountCents: -5000, categoryId: "groceries" },
        { date: "2026-02-03", amountCents: -7000, categoryId: "groceries" },
        { date: "2026-02-10", amountCents: -2000 },
        { date: "2025-12-24", amountCents: -99999, categoryId: "shopping" },
      ],
    });
    const res = await call("GET", `${f}/summary?from=2026-01-01&to=2026-12-31`);
    expect(res.status).toBe(200);
    expect(res.data.currency).toBe("EUR");
    expect([res.data.incomeCents, res.data.expenseCents, res.data.count]).toEqual([300000, 14000, 4]);
    expect(res.data.months).toEqual([
      { month: "2026-01", incomeCents: 300000, expenseCents: 5000 },
      { month: "2026-02", incomeCents: 0, expenseCents: 9000 },
    ]);
    expect(res.data.categories[0]).toEqual({ categoryId: "groceries", incomeCents: 0, expenseCents: 12000, count: 2 });
    expect(res.data.categories.some((c: any) => c.categoryId === null && c.expenseCents === 2000)).toBe(true);
  });

  it("exports and imports the finances", async () => {
    const { call, s, f, newFamily } = financeFamily();
    await call("PATCH", `${f}/settings`, { currency: "USD" });
    await call("POST", `${f}/categories`, { name: "Pets", color: "#ff0000" });
    await call("POST", `${f}/transactions`, { date: "2026-03-01", amountCents: -1234, payee: "Vet", categoryId: "pets" });
    const file = (await call("GET", `/families/${s.id}/export`)).data;
    expect(file.version).toBe(2);
    expect(file.finance.currency).toBe("USD");
    expect(file.finance.transactions.length).toBe(1);

    const target = newFamily();
    const t = `/families/${target.id}/finance`;
    await call("POST", `${t}/transactions`, { date: "2026-01-01", amountCents: 1, payee: "Old" });
    expect((await call("POST", `/families/${target.id}/import`, file)).status).toBe(200);
    const list = (await call("GET", `${t}/transactions`)).data.transactions;
    expect(list.map((x: any) => [x.payee, x.categoryId, x.amountCents])).toEqual([["Vet", "pets", -1234]]);
    expect((await call("GET", t)).data.currency).toBe("USD");

    // A file without finances (version 1) leaves them alone.
    const { finance: _, ...v1 } = file;
    await call("POST", `/families/${target.id}/import`, { ...v1, version: 1 });
    expect((await call("GET", `${t}/transactions`)).data.total).toBe(1);

    const bad = { ...file, finance: { ...file.finance, transactions: [{ date: "2026-01-01" }] } };
    expect((await call("POST", `/families/${target.id}/import`, bad)).status).toBe(400);
    // A failed import changes nothing.
    expect((await call("GET", `${t}/transactions`)).data.total).toBe(1);
  });

  it("deleting a family deletes its finances", async () => {
    const { db, call, owner, s, f } = await accountsFamily();
    await call("POST", `${f}/transactions`, { date: "2026-03-01", amountCents: -100, accountId: "checking" });
    await call("PATCH", `${f}/settings`, { currency: "CHF" });
    deleteFamily(db, { id: owner.id, admin: true }, s.id);
    for (const table of [finTransactions, finAccounts, finCategories, finSettings]) {
      expect(db.select().from(table).where(eq(table.familyId, s.id)).all()).toEqual([]);
    }
  });
});

// ------------------------------------------------------------------ accounts and transfers

describe("finance accounts and transfers", () => {
  it("tells the account balances at the end of a day", async () => {
    const { call, s, f, add, ops } = await accountsFamily();
    const [, , booking, part] = await add(
      { date: "2026-03-01", amountCents: -300, accountId: "checking" },
      { date: "2026-03-31", amountCents: 5000, accountId: "savings" },
      { date: "2026-04-02", amountCents: -200, accountId: "checking" },
      { date: "2026-04-02", amountCents: -150, accountId: "checking" },
    );
    // A part of a split booking doesn't count, its booking does.
    await ops({ action: "split", id: booking, ids: [part] });
    const at = async (day?: string) => {
      const res = await call("GET", `${f}/accounts${day ? `?at=${day}` : ""}`);
      expect(res.status, JSON.stringify(res.data)).toBe(200);
      return [res.data.at, ...res.data.accounts.map((a: any) => a.balanceCents)];
    };
    expect(await at("2026-02-28")).toEqual(["2026-02-28", 1000, 0]);
    expect(await at("2026-03-01")).toEqual(["2026-03-01", 700, 0]);
    expect(await at("2026-03-31")).toEqual(["2026-03-31", 700, 5000]);
    expect(await at("2026-04-02")).toEqual(["2026-04-02", 500, 5000]);
    expect(await at()).toEqual([null, 500, 5000]);
    expect((await call("GET", `${f}/accounts?at=2026-13-01`)).status).toBe(400);
    // Viewers can read it.
    expect((await s.view("GET", `/families/${s.id}/finance/accounts?at=2026-03-01`)).data.accounts.length).toBe(2);
  });

  it("manages finance accounts with balances", async () => {
    const { call, s, f, add } = await accountsFamily();
    const overview = (await call("GET", f)).data;
    expect(overview.accounts).toEqual([
      { id: "checking", name: "Checking", color: "#3b82f6", icon: "", openingCents: 1000, position: 0, balanceCents: 1000 },
      { id: "savings", name: "Savings", color: "#22c55e", icon: "", openingCents: 0, position: 1, balanceCents: 0 },
    ]);
    await add(
      { date: "2026-03-01", amountCents: -300, accountId: "checking" },
      { date: "2026-03-02", amountCents: 5000, accountId: "Savings" },
      { date: "2026-03-03", amountCents: -99 },
    );
    expect((await call("GET", f)).data.accounts.map((a: any) => a.balanceCents)).toEqual([700, 5000]);
    // The settings answer has them too.
    expect((await call("PATCH", `${f}/settings`, {})).data.accounts.length).toBe(2);

    const created = await call("POST", `${f}/accounts`, { name: "Cash", color: "#ff0000", icon: "💶", openingCents: -50 });
    expect(created.status).toBe(201);
    expect([created.data.id, created.data.balanceCents]).toEqual(["cash", -50]);
    expect((await call("POST", `${f}/accounts`, { name: "X", color: "red" })).status).toBe(400);
    expect((await call("POST", `${f}/accounts`, { name: "X", color: "#000000", openingCents: 1.5 })).status).toBe(400);
    const patched = await call("PATCH", `${f}/accounts/Checking`, { openingCents: 2000, position: 9 });
    expect([patched.data.balanceCents, patched.data.position]).toEqual([1700, 9]);
    expect((await call("PATCH", `${f}/accounts/nope`, { name: "Y" })).status).toBe(404);

    // Unknown accounts are refused like unknown categories.
    const bad = await call("POST", `${f}/transactions`, { date: "2026-03-01", amountCents: 1, accountId: "nope" });
    expect(bad.status).toBe(404);

    // Viewers read, editors change.
    const view = `/families/${s.id}/finance`;
    expect((await s.view("GET", view)).data.accounts.length).toBe(3);
    expect((await s.view("POST", `${view}/accounts`, { name: "A", color: "#000000" })).status).toBe(403);
    expect((await s.view("PATCH", `${view}/accounts/cash`, { name: "B" })).status).toBe(403);
    expect((await s.view("DELETE", `${view}/accounts/cash`)).status).toBe(403);

    // Deleting an account deletes its transactions too.
    expect((await call("DELETE", `${f}/accounts/savings`)).data).toEqual({ deleted: "savings", transactions: 1 });
    expect((await call("DELETE", `${f}/accounts/savings`)).status).toBe(404);
    const rows = (await call("GET", `${f}/transactions?account=none`)).data.transactions;
    expect(rows.map((t: any) => t.amountCents)).toEqual([-99]);
    const checking = (await call("GET", `${f}/transactions?account=checking`)).data;
    expect(checking.transactions.map((t: any) => t.accountId)).toEqual(["checking"]);
  });

  it("deleting an account leaves the other leg of its transfers alone", async () => {
    const { call, f, add, ops, list } = await accountsFamily();
    const [out, into] = await add(
      { date: "2026-03-10", amountCents: -50000, accountId: "checking" },
      { date: "2026-03-11", amountCents: 50000, accountId: "savings" },
    );
    await ops({ action: "link", ids: [out, into] });
    expect((await call("DELETE", `${f}/accounts/savings`)).data.transactions).toBe(1);
    const rows = (await list()).transactions;
    expect(rows.map((t: any) => [t.id, t.transferId])).toEqual([[out, null]]);
  });

  it("deleting an account keeps the parts of its split bookings on other accounts", async () => {
    const { call, f, add, ops, list } = await accountsFamily();
    const [booking, part] = await add(
      { date: "2026-03-10", amountCents: -500, accountId: "savings" },
      { date: "2026-03-10", amountCents: -300, accountId: "checking" },
    );
    await ops({ action: "split", id: booking, ids: [part] });
    expect((await call("DELETE", `${f}/accounts/savings`)).status).toBe(200);
    const rows = (await list()).transactions;
    expect(rows.map((t: any) => [t.id, t.splitOf])).toEqual([[part, null]]);
  });

  it("transfers count once by their net", async () => {
    const { call, f, add, ops, list } = await accountsFamily();
    const [out, into, coffee] = await add(
      { date: "2026-03-10", amountCents: -50000, payee: "To savings", accountId: "checking" },
      { date: "2026-03-11", amountCents: 50000, payee: "From checking", accountId: "savings" },
      { date: "2026-03-12", amountCents: -350, payee: "Café", accountId: "checking" },
    );
    expect([(await list()).incomeCents, (await list()).expenseCents]).toEqual([50000, 50350]);
    const linked = await ops({ action: "link", ids: [out, into] });
    expect(linked.changed).toBe(2);
    let all = await list();
    expect([all.incomeCents, all.expenseCents, all.total]).toEqual([0, 350, 3]);
    const transferId = all.transactions.find((t: any) => t.id === out).transferId;
    expect(transferId).toMatch(/^[0-9a-f-]{36}$/);
    expect(all.transactions.find((t: any) => t.id === into).transferId).toBe(transferId);
    expect(all.transactions.find((t: any) => t.id === coffee).transferId).toBeNull();
    // Balances still move between the accounts.
    expect((await call("GET", f)).data.accounts.map((a: any) => a.balanceCents)).toEqual([1000 - 50000 - 350, 50000]);

    // Kinds: a net-0 transfer is neither income nor expense.
    expect((await list("kind=transfer")).transactions.length).toBe(2);
    expect((await list("kind=income")).total).toBe(0);
    expect((await list("kind=expense")).transactions.map((t: any) => t.id)).toEqual([coffee]);

    const summary = (await call("GET", `${f}/summary?from=2026-01-01&to=2026-12-31`)).data;
    expect([summary.incomeCents, summary.expenseCents, summary.count]).toEqual([0, 350, 1]);

    // 500 out, only 480 arrive: the transfer costs 20.
    await ops({ action: "update", id: into, amountCents: 48000 });
    all = await list();
    expect([all.incomeCents, all.expenseCents]).toEqual([0, 2350]);
    const expense = await list("kind=expense");
    expect(expense.transactions.map((t: any) => t.id).sort()).toEqual([out, into, coffee].sort());
    expect(expense.expenseCents).toBe(2350);

    // Unlinking either leg dissolves the group; the inverse links it again.
    const unlinked = await ops({ action: "unlink", id: into });
    expect(unlinked.changed).toBe(2);
    expect((await list()).transactions.every((t: any) => t.transferId === null)).toBe(true);
    expect((await list()).incomeCents).toBe(48000);
    await ops(...unlinked.inverse);
    expect((await list("kind=transfer")).transactions.map((t: any) => t.transferId)).toEqual([transferId, transferId]);
    // The inverse of the link puts everything back the way it was.
    await ops(...linked.inverse);
    expect((await list("kind=transfer")).total).toBe(0);

    // Validation.
    const status = async (body: unknown) => (await call("POST", `${f}/transactions`, body)).status;
    expect(await status({ action: "link", ids: [out] })).toBe(400);
    expect(await status({ action: "link", ids: [out, out] })).toBe(400);
    expect(await status({ action: "link", ids: [out, crypto.randomUUID()] })).toBe(404);
    expect(await status({ action: "unlink", ids: ["x"] })).toBe(400);
    expect(await status({ action: "update", id: out, transferId: "nope" })).toBe(400);
  });

  it("a transfer across a month boundary counts once, in its lead leg's month", async () => {
    const { call, f, add, ops, list } = await accountsFamily();
    const [out, into] = await add(
      { date: "2026-01-31", amountCents: -10000, accountId: "checking", categoryId: "vacation" },
      { date: "2026-02-01", amountCents: 9000, accountId: "savings" },
    );
    await ops({ action: "link", ids: [into, out] });
    const summary = (await call("GET", `${f}/summary?from=2026-01-01&to=2026-12-31`)).data;
    expect(summary.months).toEqual([{ month: "2026-01", incomeCents: 0, expenseCents: 1000 }]);
    expect(summary.categories).toEqual([{ categoryId: "vacation", incomeCents: 0, expenseCents: 1000, count: 1 }]);
    // A range with only the second leg doesn't count the group (its lead is in January), but
    // still knows it is a leg of one.
    const feb = await list("from=2026-02-01&to=2026-02-28");
    expect([feb.incomeCents, feb.expenseCents]).toEqual([0, 0]);
    expect(feb.transactions[0].transferId).not.toBeNull();
    expect((await list("from=2026-02-01&to=2026-02-28&kind=expense")).total).toBe(1);
    const jan = await list("from=2026-01-01&to=2026-01-31");
    expect([jan.incomeCents, jan.expenseCents]).toEqual([0, 1000]);
    const febSummary = (await call("GET", `${f}/summary?from=2026-02-01&to=2026-02-28`)).data;
    expect([febSummary.count, febSummary.months]).toEqual([0, []]);
  });

  it("deleting a leg clears the other's transfer, and undo restores both", async () => {
    const { add, ops, list } = await accountsFamily();
    const [a, b, c] = await add(
      { date: "2026-05-01", amountCents: -1000, accountId: "checking" },
      { date: "2026-05-01", amountCents: 600, accountId: "savings" },
      { date: "2026-05-02", amountCents: 400, accountId: "savings" },
    );
    await ops({ action: "link", ids: [a, b, c] });
    const before = (await list()).transactions;
    const transferId = before[0].transferId;

    // Three legs: deleting one leaves a group of two.
    const first = await ops({ action: "delete", ids: [c] });
    expect((await list("kind=transfer")).total).toBe(2);
    // Two legs: deleting one leaves a lone leg, which leaves the group.
    const second = await ops({ action: "delete", ids: [b] });
    const [lone] = (await list()).transactions;
    expect([lone.id, lone.transferId]).toEqual([a, null]);
    expect((await list()).expenseCents).toBe(1000);

    await ops(...second.inverse);
    await ops(...first.inverse);
    const after = (await list()).transactions;
    expect(after).toEqual(before);
    expect(after.every((t: any) => t.transferId === transferId)).toBe(true);
    expect([(await list()).incomeCents, (await list()).expenseCents]).toEqual([0, 0]);

    // Linking a leg into a new group: the rest of its old group stays a group if it has two
    // legs, a leg left alone loses its transfer; the inverse restores all of it.
    const [d] = await add({ date: "2026-05-03", amountCents: -1000, accountId: "savings" });
    const relink = await ops({ action: "link", ids: [a, d] });
    const transfers = async (...ids: string[]) => {
      const rows = (await list()).transactions;
      return ids.map((x) => rows.find((t: any) => t.id === x).transferId);
    };
    expect(await transfers(b, c)).toEqual([transferId, transferId]);
    const [newId] = await transfers(a);
    expect(newId && newId !== transferId).toBe(true);
    expect(await transfers(d)).toEqual([newId]);
    const again = await ops({ action: "link", ids: [b, d] });
    expect(await transfers(a, c)).toEqual([null, null]);
    expect((await list("kind=transfer")).transactions.map((t: any) => t.id).sort()).toEqual([b, d].sort());
    await ops(...again.inverse);
    expect(await transfers(a, b, c, d)).toEqual([newId, transferId, transferId, newId]);
    await ops(...relink.inverse);
    expect((await list()).transactions.filter((t: any) => t.id !== d)).toEqual(before);
  });

  it("suggests transfers between accounts", async () => {
    const { call, s, f, add, ops } = await accountsFamily();
    const [out1, in1, out2, in2] = await add(
      { date: "2026-06-01", amountCents: -20000, accountId: "checking" },
      { date: "2026-06-03", amountCents: 20000, accountId: "savings" },
      { date: "2026-06-02", amountCents: -20000, accountId: "checking" },
      { date: "2026-06-02", amountCents: 20000, accountId: "savings" },
      { date: "2026-06-20", amountCents: -7000, accountId: "checking" },
      { date: "2026-06-25", amountCents: 7000, accountId: "savings" }, // 5 days: too far
      { date: "2026-06-10", amountCents: -500, accountId: "checking" },
      { date: "2026-06-10", amountCents: 500, accountId: "checking" }, // same account
      { date: "2026-06-11", amountCents: -800 },
      { date: "2026-06-11", amountCents: 800 }, // both without an account
    );
    const res = await s.view("GET", `/families/${s.id}/finance/transfers/suggestions`);
    expect(res.status).toBe(200);
    // Closest days first: out2 and in2 on the same day, then out1 with in1. Newest first.
    expect(res.data.pairs.map((p: any) => [p.out.id, p.in.id])).toEqual([
      [out1, in1],
      [out2, in2],
    ]);
    expect(res.data.pairs[0].in.accountId).toBe("savings");
    const ranged = await call("GET", `${f}/transfers/suggestions?from=2026-06-02&to=2026-06-30`);
    expect(ranged.data.pairs.map((p: any) => p.out.id)).toEqual([out2]);
    expect((await call("GET", `${f}/transfers/suggestions?from=x`)).status).toBe(400);
    // Grouped transactions aren't suggested again.
    await ops({ action: "link", ids: [out2, in2] });
    const after = await call("GET", `${f}/transfers/suggestions`);
    expect(after.data.pairs.map((p: any) => p.out.id)).toEqual([out1]);
  });

  it("auto-combines transfers, and the inverse splits them again", async () => {
    const { call, s, f, add, ops, list } = await accountsFamily();
    await add(
      { date: "2026-06-01", amountCents: -20000, accountId: "checking" },
      { date: "2026-06-02", amountCents: 20000, accountId: "savings" },
      { date: "2026-07-01", amountCents: -3000, accountId: "savings" },
      { date: "2026-07-01", amountCents: 3000, accountId: "checking" },
      { date: "2026-08-01", amountCents: -100, accountId: "savings" },
      { date: "2026-08-01", amountCents: 100, accountId: "checking" },
    );
    expect((await s.view("POST", `/families/${s.id}/finance/transfers/auto`, {})).status).toBe(403);
    expect((await call("POST", `${f}/transfers/auto`, { from: "nope" })).status).toBe(400);
    const res = await call("POST", `${f}/transfers/auto`, { from: "2026-06-01", to: "2026-07-31" });
    expect(res.status).toBe(200);
    expect([res.data.ok, res.data.linked, res.data.changed]).toEqual([true, 2, 4]);
    expect((await list("kind=transfer")).total).toBe(4);
    expect([(await list()).incomeCents, (await list()).expenseCents]).toEqual([100, 100]);
    const groups = new Set((await list("kind=transfer")).transactions.map((t: any) => t.transferId));
    expect(groups.size).toBe(2);
    await ops(...res.data.inverse);
    expect((await list("kind=transfer")).total).toBe(0);
    // Without a range: the whole history.
    expect((await call("POST", `${f}/transfers/auto`, {})).data.linked).toBe(3);
    expect((await call("POST", `${f}/transfers/auto`, {})).data).toEqual({
      ok: true,
      changed: 0,
      added: [],
      inverse: [],
      linked: 0,
      splits: 0,
    });
  });

  it("imports a statement into an account", async () => {
    const { call, f, list } = await accountsFamily();
    const rows = [{ date: "2026-05-02", amountCents: -350, payee: "Café", description: "Coffee" }];
    expect((await call("POST", `${f}/import`, { rows, accountId: "nope" })).status).toBe(404);
    const dry = await call("POST", `${f}/import`, { rows, dryRun: true, accountId: "Checking" });
    expect([dry.data.added, dry.data.duplicates, dry.data.transfers]).toEqual([0, [], 0]);
    expect((await list()).total).toBe(0);
    const first = await call("POST", `${f}/import`, { rows, accountId: "checking" });
    expect(first.data.added).toBe(1);
    expect((await list()).transactions[0].accountId).toBe("checking");
    // The same booking on another account's statement isn't a duplicate…
    const other = await call("POST", `${f}/import`, { rows, accountId: "savings" });
    expect([other.data.added, other.data.duplicates]).toEqual([1, []]);
    // …but on the same account's statement it is, and without an account the hash is as before.
    const again = await call("POST", `${f}/import`, { rows, accountId: "checking", dryRun: true });
    expect(again.data.duplicates).toEqual([0]);
    const plain = await call("POST", `${f}/import`, { rows });
    expect(plain.data.added).toBe(1);
    expect((await call("POST", `${f}/import`, { rows })).data.duplicates).toEqual([0]);
    expect((await list("account=none")).total).toBe(1);
  });

  it("an import can combine transfers automatically", async () => {
    const { call, f, add, list } = await accountsFamily();
    const [out] = await add(
      { date: "2026-05-01", amountCents: -20000, payee: "To savings", accountId: "checking" },
      // An older pair that isn't combined: not touched by the import.
      { date: "2026-04-01", amountCents: -5000, accountId: "checking" },
      { date: "2026-04-01", amountCents: 5000, accountId: "savings" },
    );
    const rows = [
      { date: "2026-05-03", amountCents: 20000, payee: "From checking" },
      { date: "2026-05-04", amountCents: -999, payee: "Bank fee" },
    ];
    const body = { rows, accountId: "savings", autoTransfers: true };
    const dry = await call("POST", `${f}/import`, { ...body, dryRun: true });
    expect([dry.data.added, dry.data.transfers]).toEqual([0, 1]);
    expect((await list()).total).toBe(3);
    expect((await list("kind=transfer")).total).toBe(0);

    // Without the flag nothing is linked.
    const without = await call("POST", `${f}/import`, { rows: [rows[1]], accountId: "savings" });
    expect(without.data.transfers).toBe(0);
    expect((await list("kind=transfer")).total).toBe(0);

    const res = await call("POST", `${f}/import`, body);
    expect([res.data.added, res.data.duplicates, res.data.transfers]).toEqual([1, [1], 1]);
    const legs = (await list("kind=transfer")).transactions;
    expect(legs.map((t: any) => t.id).sort()).toEqual([out, res.data.ids[0]].sort());
    expect(legs[0].transferId).toBe(legs[1].transferId);
    // Undoing the import (deleting its rows) leaves the other leg alone again.
    await call("POST", `${f}/transactions`, { action: "delete", ids: res.data.ids });
    expect((await list("kind=transfer")).total).toBe(0);
  });

  it("exports, imports and copies accounts and transfers", async () => {
    const { call, s, add, ops, newFamily, store } = await accountsFamily();
    const [a, b] = await add(
      { date: "2026-03-01", amountCents: -500, accountId: "checking" },
      { date: "2026-03-01", amountCents: 500, accountId: "savings" },
    );
    await ops({ action: "link", ids: [a, b] });
    const file = (await call("GET", `/families/${s.id}/export`)).data;
    expect(file.finance.accounts.map((x: any) => [x.id, x.openingCents])).toEqual([
      ["checking", 1000],
      ["savings", 0],
    ]);
    expect(file.finance.transactions.every((t: any) => t.transferId && t.accountId)).toBe(true);

    const target = newFamily();
    const t = `/families/${target.id}/finance`;
    expect((await call("POST", `/families/${target.id}/import`, file)).status).toBe(200);
    expect((await call("GET", t)).data.accounts.map((x: any) => x.balanceCents)).toEqual([500, 500]);
    const imported = (await call("GET", `${t}/transactions?kind=transfer`)).data;
    expect([imported.total, imported.incomeCents, imported.expenseCents]).toEqual([2, 0, 0]);

    // Files from before accounts still import.
    const old = {
      ...file,
      finance: {
        ...file.finance,
        accounts: undefined,
        transactions: file.finance.transactions.map(({ accountId: _, transferId: __, ...x }: any) => x),
      },
    };
    expect((await call("POST", `/families/${target.id}/import`, old)).status).toBe(200);
    expect((await call("GET", t)).data.accounts).toEqual([]);
    expect((await call("GET", `${t}/transactions`)).data.incomeCents).toBe(500);
    // A transaction with an unknown account is refused.
    const bad = { ...file, finance: { ...file.finance, accounts: [] } };
    expect((await call("POST", `/families/${target.id}/import`, bad)).status).toBe(400);

    // A copy (family-planner's clone) has the accounts and the transfers, with its own ids.
    const copy = newFamily();
    await store.clearFinance(copy.id);
    await copyFinance(store, s.id, copy.id);
    const c = `/families/${copy.id}/finance`;
    expect((await call("GET", c)).data.accounts.map((x: any) => x.id)).toEqual(["checking", "savings"]);
    const legs = (await call("GET", `${c}/transactions?kind=transfer`)).data.transactions;
    expect(legs.length).toBe(2);
    expect(legs[0].transferId).toBe(legs[1].transferId);
    expect(legs[0].transferId).not.toBe(file.finance.transactions[0].transferId);
  });
});

// ------------------------------------------------------------------ split bookings

const SPLIT_STATEMENT = [
  { date: "2026-12-17", amountCents: -355, payee: "Amazon Payments", description: "Splitbuchung" },
  { date: "2026-12-17", amountCents: -6491, payee: "Amazon Payments", description: "Splitbuchung" },
  { date: "2026-12-17", amountCents: -395, payee: "AMAZON EU S.A R.L.", description: "Bestellnr. 1" },
  { date: "2026-12-17", amountCents: 40, payee: "AMAZON EU S.A R.L.", description: "Bestellnr. 1" },
  { date: "2026-12-17", amountCents: -6491, payee: "Amazon.de", description: "Bestellnr. 2 CASO" },
  { date: "2026-12-17", amountCents: -2000, payee: "REWE", description: "Groceries" },
  { date: "2026-12-20", amountCents: -899, payee: "Amazon Prime", description: "Membership" },
  { date: "2026-12-24", amountCents: -2498, payee: "Amazon Payments", description: "Splitbuchung" },
  { date: "2026-12-24", amountCents: -2199, payee: "Amazon.de", description: "Bestellnr. 3" },
  { date: "2026-12-30", amountCents: -2495, payee: "Amazon Payments", description: "Splitbuchung" },
  { date: "2026-12-30", amountCents: -466, payee: "Amazon.de", description: "Bestellnr. 4" },
  { date: "2026-12-30", amountCents: -2495, payee: "Amazon.de", description: "Bestellnr. 4 Ginkgo" },
  { date: "2026-12-30", amountCents: 499, payee: "Amazon.de", description: "Gutschein" },
];
/** What the statement adds up to: the bookings and the other rows, not the order lines. */
const SPLIT_STATEMENT_NET = -(355 + 6491 + 2000 + 899 + 2498 + 2495);

/** A checking account statement whose order lines have no payee: they name their order
 *  ("Bestellnr."), as does the bank's booking, which isn't marked "Splitbuchung". */
const AMAZON = "AMAZON PAYMENTS EUROPE S.C.A.";
const ORDER_STATEMENT = [
  { date: "2026-01-02", amountCents: -7289, payee: AMAZON, description: "306-0265205-1111111 AMZN" },
  { date: "2026-01-02", amountCents: -7289, payee: "", description: "Fleece Bestellnr. 306-0265205-1111111" },
  // An order line booked a day later.
  { date: "2026-01-03", amountCents: -500, payee: "", description: "Cap Bestellnr. 306-0265205-1111111" },
  // Two charges for one order, and an order line listed twice.
  { date: "2026-05-20", amountCents: -7295, payee: AMAZON, description: "306-6954512-2222222" },
  { date: "2026-05-20", amountCents: -2804, payee: AMAZON, description: "306-6954512-2222222" },
  { date: "2026-05-20", amountCents: -2804, payee: "", description: "Wiper Bestellnr. 306-6954512-2222222" },
  { date: "2026-05-20", amountCents: -2804, payee: "", description: "Wiper Bestellnr. 306-6954512-2222222 " },
  { date: "2026-05-20", amountCents: -7295, payee: "", description: "Board Bestellnr. 306-6954512-2222222" },
  // A discount: the order line is more than the booking.
  { date: "2026-05-20", amountCents: -1359, payee: AMAZON, description: "306-1227454-3333333" },
  { date: "2026-05-20", amountCents: -1699, payee: "", description: "Lock Bestellnr. 306-1227454-3333333" },
  // An order line months after its order's booking stays alone.
  { date: "2026-05-21", amountCents: -500, payee: "", description: "Cable Bestellnr. 306-0265205-1111111" },
];

/** January's Amazon rows of a checking account statement (with a "Splitbuchung" column, true
 *  for the order lines): a refund's order line is listed twice, once by the bank. */
const JANUARY_AMAZON = [
  {
    date: "2026-01-12",
    amountCents: -1198,
    payee: "AMAZON EU S.A R.L., NIEDERLASSUNG DEUTSCHLAND",
    description: "306-0582276-2307564 Amazon.de 1Y7CA  7VM96XQJW7Z",
  },
  {
    date: "2026-01-12",
    amountCents: -1198,
    payee: "",
    description: "tesa INSULATION Fenster-Isolierfolie Bestellnr. 306-0582276-2307564",
  },
  {
    date: "2026-01-14",
    amountCents: -1177,
    payee: "AMAZON EU S.A R.L., NIEDERLASSUNG DEUTSCHLAND",
    description: "306-2295250-0932308 Amazon.de 58PAO  3MUUGGKX28W",
  },
  {
    date: "2026-01-14",
    amountCents: -1177,
    payee: "",
    description: "Doppelherz Omega-3 Seefischoel 1000 Bestellnr. 306-2295250-0932308",
  },
  {
    date: "2026-01-14",
    amountCents: 1198,
    payee: "AMAZON EU S.A R.L., NIEDERLASSUNG DEUTSCHLAND",
    description: "306-0582276-2307564 Amazon.de 1NJ2I  1WOZFDK72RD",
  },
  { date: "2026-01-14", amountCents: 1198, payee: "", description: "Erstattung Bestellnr. 306-0582276-2307564" },
  {
    date: "2026-01-14",
    amountCents: 1198,
    payee: "",
    description: "COMDIRECT BANK AG0800 Bestellnummer 306-0582276-2307564 Erstattung",
  },
  {
    date: "2026-01-23",
    amountCents: -1435,
    payee: "AMAZON PAYMENTS EUROPE S.C.A.",
    description: "305-9356245-3073956 AMZN Mktp DE 5X  MTBO28KNURUUSB",
  },
];
/** What the bank booked: the rows without the order lines. */
const JANUARY_AMAZON_NET = -1198 - 1177 + 1198 - 1435;

describe("finance split bookings", () => {
  it("an import combines split bookings, so their order lines don't count twice", async () => {
    const { call, f, add, list } = await accountsFamily();
    // An Amazon card payment the day before the voucher: not a transfer.
    await add({ date: "2026-12-29", amountCents: -499, payee: "AMAZON.DE", accountId: "savings" });
    const body = { rows: SPLIT_STATEMENT, accountId: "checking", autoTransfers: true };
    const dry = await call("POST", `${f}/import`, { ...body, dryRun: true });
    expect([dry.data.added, dry.data.splits, dry.data.transfers]).toEqual([0, 4, 0]);

    const res = await call("POST", `${f}/import`, body);
    expect([res.data.added, res.data.splits, res.data.transfers]).toEqual([13, 4, 0]);
    const all = await list("from=2026-12-01&to=2026-12-31&account=checking");
    expect(all.incomeCents - all.expenseCents).toBe(SPLIT_STATEMENT_NET);
    const byText = (amount: number, text: string) =>
      all.transactions.find((t: any) => t.amountCents === amount && t.description.includes(text));
    const bookings = all.transactions
      .filter((t: any) => t.split)
      .map((t: any) => [t.date, t.amountCents, t.split.parts, t.split.remainderCents]);
    expect(bookings).toEqual([
      ["2026-12-30", -2495, 3, -33],
      ["2026-12-24", -2498, 1, -299],
      ["2026-12-17", -355, 2, 0],
      ["2026-12-17", -6491, 1, 0],
    ]);
    // Several bookings on one day each take the order lines that add up to them.
    const small = byText(-355, "Splitbuchung");
    expect(byText(-395, "Bestellnr. 1").splitOf).toBe(small.id);
    expect(byText(40, "Bestellnr. 1").splitOf).toBe(small.id);
    expect(byText(-6491, "CASO").splitOf).toBe(byText(-6491, "Splitbuchung").id);
    expect([byText(-2000, "Groceries").splitOf, byText(-899, "Membership").splitOf]).toEqual([null, null]);
    expect((await list("kind=transfer")).total).toBe(0);
    // The balance counts the bookings, not their parts.
    const accounts = (await call("GET", f)).data.accounts;
    expect(accounts[0].balanceCents).toBe(1000 + SPLIT_STATEMENT_NET);

    // Importing the statement again changes nothing.
    const again = await call("POST", `${f}/import`, body);
    expect([again.data.added, again.data.splits]).toEqual([0, 0]);
  });

  it("auto-combine finds split bookings by their order number", async () => {
    const { call, f, list } = await accountsFamily();
    const body = { rows: ORDER_STATEMENT, accountId: "checking", autoTransfers: true };
    const res = await call("POST", `${f}/import`, body);
    expect([res.data.added, res.data.splits, res.data.transfers]).toEqual([11, 4, 0]);
    const all = await list("account=checking");
    const bookings = all.transactions
      .filter((t: any) => t.split)
      .map((t: any) => [t.date, t.amountCents, t.split.parts, t.split.remainderCents]);
    // Every order line is a part, so the bookings count as the bank booked them: the line listed
    // twice and the discount even out in the remainder.
    expect(bookings).toEqual([
      ["2026-05-20", -7295, 2, 2804],
      ["2026-05-20", -2804, 1, 0],
      ["2026-05-20", -1359, 1, 340],
      ["2026-01-02", -7289, 2, 500],
    ]);
    const alone = all.transactions.filter((t: any) => !t.split && !t.splitOf).map((t: any) => `${t.date} ${t.amountCents}`);
    expect(alone).toEqual(["2026-05-21 -500"]);
    expect(all.incomeCents - all.expenseCents).toBe(-(7289 + 7295 + 2804 + 1359 + 500));
  });

  it("auto-combine gives a split booking the order lines it is still missing", async () => {
    const { call, f, ops, list } = await accountsFamily();
    const res = await call("POST", `${f}/import`, { rows: JANUARY_AMAZON, accountId: "checking" });
    const ids: string[] = res.data.ids;
    // As before: the refund took only one of its two order lines.
    await ops({ action: "split", id: ids[4], ids: [ids[5]] });
    const before = await list("account=checking");
    expect(before.incomeCents - before.expenseCents).toBe(-1198 * 2 - 1177 * 2 + 1198 * 2 - 1435);

    const auto = (await call("POST", `${f}/transfers/auto`, {})).data;
    expect([auto.splits, auto.linked]).toEqual([3, 0]);
    const all = await list("account=checking");
    expect(all.incomeCents - all.expenseCents).toBe(JANUARY_AMAZON_NET);
    const refund = all.transactions.find((t: any) => t.id === ids[4]);
    expect([refund.split.parts, refund.split.remainderCents]).toEqual([2, -1198]);
    expect(all.transactions.find((t: any) => t.id === ids[6]).splitOf).toBe(ids[4]);

    // Undo takes back only the new parts.
    await ops(...auto.inverse);
    const undone = await list("account=checking");
    expect(undone.incomeCents - undone.expenseCents).toBe(before.incomeCents - before.expenseCents);
    expect(undone.transactions.find((t: any) => t.id === ids[5]).splitOf).toBe(ids[4]);
  });

  it("auto-combine turns a voucher wrongly combined as a transfer into a part", async () => {
    const { call, f, add, ops, list } = await accountsFamily();
    const [card] = await add({ date: "2026-12-29", amountCents: -499, payee: "AMAZON.DE", accountId: "savings" });
    const ids = await add(...SPLIT_STATEMENT.map((r) => ({ ...r, accountId: "checking" })));
    const voucher = ids[12];
    await ops({ action: "link", ids: [card, voucher] });
    expect((await list("kind=transfer")).total).toBe(2);
    // "Find transfers" doesn't suggest order lines either.
    await ops({ action: "unlink", id: card });
    expect((await call("GET", `${f}/transfers/suggestions`)).data.pairs).toEqual([]);
    await ops({ action: "link", ids: [card, voucher] });

    const res = await call("POST", `${f}/transfers/auto`, {});
    expect([res.data.splits, res.data.linked]).toEqual([4, 0]);
    expect((await list("kind=transfer")).total).toBe(0);
    const year = await list("from=2026-12-01&to=2026-12-31&account=checking");
    expect(year.incomeCents - year.expenseCents).toBe(SPLIT_STATEMENT_NET);
    expect((await list("account=savings")).expenseCents).toBe(499);

    // Undo puts the transfer back and the order lines back on their own.
    await ops(...res.data.inverse);
    const after = await list();
    expect(after.transactions.filter((t: any) => t.split || t.splitOf)).toEqual([]);
    expect((await list("kind=transfer")).total).toBe(2);
  });

  it("transactions can be split and unsplit by hand", async () => {
    const { call, f, add, ops, list } = await accountsFamily();
    const [booking, a, b, other, c, d] = await add(
      { date: "2026-03-01", amountCents: -5000, payee: "Shop", accountId: "checking" },
      { date: "2026-03-01", amountCents: -3000, categoryId: "groceries" },
      { date: "2026-03-01", amountCents: -1500, categoryId: "kids" },
      { date: "2026-03-02", amountCents: -100, accountId: "checking" },
      { date: "2026-03-02", amountCents: -500, accountId: "checking" },
      { date: "2026-03-02", amountCents: 500, accountId: "savings" },
    );
    const bad = async (op: Record<string, unknown>, status = 400) =>
      expect((await call("POST", `${f}/transactions`, op)).status).toBe(status);
    await bad({ action: "split", ids: [a] });
    await bad({ action: "split", id: booking, ids: [booking] });
    await bad({ action: "split", id: booking, ids: [crypto.randomUUID()] }, 404);

    const res = await ops({ action: "split", id: booking, ids: [a, b] });
    expect(res.changed).toBe(3);
    const month = await list("from=2026-03-01&to=2026-03-01");
    expect([month.incomeCents, month.expenseCents]).toEqual([0, 5000]);
    const row = (id: string) => month.transactions.find((t: any) => t.id === id);
    expect(row(booking).split).toEqual({ parts: 2, remainderCents: -500 });
    expect([row(a).splitOf, row(b).splitOf, row(booking).splitOf]).toEqual([booking, booking, null]);
    // Each part counts in its own category, the rest in the booking's (none).
    const summary = (await call("GET", `${f}/summary?from=2026-03-01&to=2026-03-01`)).data;
    expect(summary.categories.map((c: any) => [c.categoryId, c.expenseCents])).toEqual([
      ["groceries", 3000],
      ["kids", 1500],
      [null, 500],
    ]);

    // Parts and bookings can't be transfer legs, and parts can't have parts.
    await bad({ action: "link", ids: [booking, d] });
    await bad({ action: "link", ids: [a, d] });
    await bad({ action: "split", id: a, ids: [other] });
    await bad({ action: "split", id: other, ids: [booking] });
    await bad({ action: "update", id: a, transferId: crypto.randomUUID() });
    // A transfer leg that becomes a part leaves its transfer.
    await ops({ action: "link", ids: [c, d] });
    await ops({ action: "split", id: other, ids: [c] });
    expect((await list("kind=transfer")).total).toBe(0);
    await ops({ action: "unsplit", ids: [c] });

    // Deleting the booking keeps its parts; undo makes them parts again.
    const del = await ops({ action: "delete", ids: [booking] });
    expect((await list("from=2026-03-01&to=2026-03-01")).expenseCents).toBe(4500);
    expect((await list()).transactions.every((t: any) => !t.splitOf)).toBe(true);
    await ops(...del.inverse);
    expect((await list()).transactions.find((t: any) => t.id === a).splitOf).toBe(booking);
    expect((await list("from=2026-03-01&to=2026-03-01")).expenseCents).toBe(5000);

    // Unsplitting a part takes just it out; unsplitting the booking all of them.
    await ops({ action: "unsplit", ids: [a] });
    let rows = (await list()).transactions;
    expect(rows.find((t: any) => t.id === booking).split).toEqual({ parts: 1, remainderCents: -3500 });
    const undo = await ops({ action: "unsplit", ids: [booking] });
    rows = (await list()).transactions;
    expect(rows.filter((t: any) => t.split || t.splitOf)).toEqual([]);
    expect((await list("from=2026-03-01&to=2026-03-01")).expenseCents).toBe(9500);
    // Undo gives the booking back the part it had (a was taken out before).
    await ops(...undo.inverse);
    expect((await list("from=2026-03-01&to=2026-03-01")).expenseCents).toBe(8000);
  });

  it("exports, imports and copies keep split bookings", async () => {
    const { call, s, add, ops, newFamily, store } = await accountsFamily();
    const [booking, a, b] = await add(
      { date: "2026-03-01", amountCents: -5000, accountId: "checking" },
      { date: "2026-03-01", amountCents: -3000, accountId: "checking" },
      { date: "2026-03-01", amountCents: -2000, accountId: "checking" },
    );
    await ops({ action: "split", id: booking, ids: [a, b] });
    const file = (await call("GET", `/families/${s.id}/export`)).data;
    expect(file.finance.transactions.filter((t: any) => t.splitOf === booking).length).toBe(2);
    const check = async (familyId: string) => {
      const t = `/families/${familyId}/finance`;
      const res = (await call("GET", `${t}/transactions`)).data;
      expect([res.incomeCents, res.expenseCents]).toEqual([0, 5000]);
      const top = res.transactions.find((t: any) => t.split);
      expect(top.split).toEqual({ parts: 2, remainderCents: 0 });
      expect(res.transactions.filter((t: any) => t.splitOf === top.id).length).toBe(2);
      expect((await call("GET", t)).data.accounts[0].balanceCents).toBe(1000 - 5000);
    };

    const target = newFamily();
    // Parts before their booking in the file import all the same.
    const reversed = { ...file, finance: { ...file.finance, transactions: [...file.finance.transactions].reverse() } };
    expect((await call("POST", `/families/${target.id}/import`, reversed)).status).toBe(200);
    await check(target.id);
    // A part whose booking isn't in the file is refused.
    const broken = {
      ...file,
      finance: { ...file.finance, transactions: file.finance.transactions.filter((t: any) => t.id !== booking) },
    };
    expect((await call("POST", `/families/${target.id}/import`, broken)).status).toBe(400);

    const copy = newFamily();
    await store.clearFinance(copy.id);
    await copyFinance(store, s.id, copy.id);
    await check(copy.id);
    const copied = (await call("GET", `/families/${copy.id}/finance/transactions`)).data;
    expect(copied.transactions.every((t: any) => t.splitOf !== booking)).toBe(true);
  });
});

describe("finance overview card", () => {
  it("sums this month's income and expenses by net counting", async () => {
    const { db, s, add, ops } = await accountsFamily();
    const [out, into] = await add(
      { date: "2026-11-02", amountCents: -20000, accountId: "checking" },
      { date: "2026-11-02", amountCents: 20000, accountId: "savings" },
      { date: "2026-11-03", amountCents: 300000, categoryId: "salary", accountId: "checking" },
      { date: "2026-11-04", amountCents: -4500, categoryId: "groceries", accountId: "checking" },
      { date: "2026-10-31", amountCents: -99999 },
      // Uncategorized: counts, but isn't where "most went".
      { date: "2026-11-05", amountCents: -9000 },
    );
    await ops({ action: "link", ids: [out, into] });
    const sum = await monthSummary(db, s.id, "2026-11-15");
    expect(sum).toMatchObject({
      currency: "EUR",
      month: "2026-11",
      incomeCents: 300000,
      expenseCents: 13500,
      count: 3,
      topExpense: { categoryId: "groceries", name: "Groceries", expenseCents: 4500 },
    });
    expect(sum.balanceCents).toBe(1000 + 300000 - 4500); // the accounts; the others have none
  });
});
