// Phase 7, Meals → Finance: a shopping list shows the groceries transactions of its shopping
// day ± 1 day, and those transactions link back to the list. Read-only, no money logic of its
// own (the totals are the finance module's net counting).

import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import { finCategories, ingredients, recipeIngredients, recipes, shoppingLists, units } from "@/lib/db/schema";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { applyTransactionOps, handleFinance } from "@/lib/finance/finance";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { groceriesCategory, listForTransaction, shoppingLinks, shoppingSpend } from "@/lib/finance/groceries";
import { setupMealPlan } from "@/lib/meals/meal-plan/setup";
import { mulberry32 } from "@/lib/meals/domain/rng";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

let db: Db;
let familyId: string;
let editorId: string;
let store: DrizzleFinanceStore;

beforeEach(() => {
  db = createTestDb();
  editorId = makeUser(db).id;
  familyId = makeFamily(db, editorId).id; // with the default categories (Groceries, …)
  store = new DrizzleFinanceStore(db);
});

const add = (date: string, amountCents: number, categoryId: string | null, payee = "Shop") =>
  applyTransactionOps(store, familyId, [{ action: "add", date, amountCents, categoryId, payee }]);

describe("the groceries category", () => {
  const cat = (id: string, name: string, parent_id: string | null = null) => ({
    family_id: "f",
    id,
    name,
    color: "#000000",
    icon: "",
    kind: "expense" as const,
    position: 0,
    parent_id,
  });

  it("is the configured one, else the one named Groceries / Lebensmittel", () => {
    const cats = [cat("food", "Food"), cat("lm", "Lebensmittel", "food"), cat("other", "Other")];
    expect(groceriesCategory(cats, null)?.id).toBe("lm");
    expect(groceriesCategory(cats, "other")?.id).toBe("other");
    // A deleted configured category falls back to the default.
    expect(groceriesCategory(cats, "gone")?.id).toBe("lm");
    expect(groceriesCategory([cat("a", "A")], null)).toBeNull();
  });
});

describe("shoppingSpend", () => {
  it("lists the groceries transactions of the shopping day ± 1 day, subcategories included", async () => {
    db.insert(finCategories)
      .values({ familyId, id: "bakery", name: "Bakery", color: "#000000", kind: "expense", parentId: "groceries" })
      .run();
    await add("2026-11-02", -4500, "groceries", "Rewe");
    await add("2026-11-03", -800, "bakery", "Bäcker");
    await add("2026-11-04", 300, "groceries", "Rewe refund");
    await add("2026-11-05", -9999, "groceries", "too late");
    await add("2026-11-03", -2000, "housing", "not groceries");
    const spend = await shoppingSpend(db, familyId, "2026-11-03");
    expect(spend.category?.id).toBe("groceries");
    expect([spend.from, spend.to]).toEqual(["2026-11-02", "2026-11-04"]);
    expect(spend.transactions.map((t) => t.payee).sort()).toEqual(["Bäcker", "Rewe", "Rewe refund"]);
    expect(spend.totalCents).toBe(4500 + 800 - 300);
  });

  it("counts a split booking by its groceries part only", async () => {
    const res = await applyTransactionOps(store, familyId, [
      { action: "add", date: "2026-11-03", amountCents: -10000, categoryId: "housing", payee: "Supermarket" },
      { action: "add", date: "2026-11-03", amountCents: -3000, categoryId: "groceries", payee: "food part" },
    ]);
    const [booking, part] = res.added;
    await applyTransactionOps(store, familyId, [{ action: "split", id: booking, ids: [part] }]);
    const spend = await shoppingSpend(db, familyId, "2026-11-03");
    expect(spend.transactions.map((t) => t.payee)).toEqual(["food part"]);
    expect(spend.totalCents).toBe(3000);
  });

  it("is empty without a groceries category", async () => {
    await store.deleteCategory(familyId, "groceries");
    const spend = await shoppingSpend(db, familyId, "2026-11-03");
    expect(spend.category).toBeNull();
    expect(spend.transactions).toEqual([]);
  });
});

describe("links from transactions to shopping lists", () => {
  it("finds the nearest list within ± 1 day of a groceries transaction", () => {
    const links = {
      categoryIds: ["groceries", "bakery"],
      lists: [
        { date: "2026-11-02", id: "mon" },
        { date: "2026-11-05", id: "thu" },
      ],
    };
    expect(listForTransaction(links, { date: "2026-11-02", categoryId: "groceries" })?.id).toBe("mon");
    expect(listForTransaction(links, { date: "2026-11-03", categoryId: "bakery" })?.id).toBe("mon");
    expect(listForTransaction(links, { date: "2026-11-04", categoryId: "groceries" })?.id).toBe("thu");
    expect(listForTransaction(links, { date: "2026-11-08", categoryId: "groceries" })).toBeNull();
    expect(listForTransaction(links, { date: "2026-11-02", categoryId: "housing" })).toBeNull();
    expect(listForTransaction(links, { date: "2026-11-02", categoryId: null })).toBeNull();
  });

  it("gives the finance page the family's shopping days", async () => {
    db.insert(units).values({ id: 1, nameEn: "gram", nameDe: "Gramm", abbreviation: "g", conversionFactor: "1" }).run();
    db.insert(ingredients).values({ id: 1, nameEn: "Tomato", nameDe: "Tomate", category: "PRODUCE" }).run();
    db.insert(recipes)
      .values({ id: "r1", familyId, title: "r1", description: "", listType: "KNOWN", defaultServings: 2, createdAt: NOW, updatedAt: NOW })
      .run();
    db.insert(recipeIngredients).values({ recipeId: "r1", ingredientId: 1, quantity: "100", unitId: 1, order: 0 }).run();
    const now = new Date("2026-06-01T08:00:00Z"); // a Monday
    setupMealPlan(db, familyId, { iterationWeeks: 1, shoppingDays: [0, 3], servings: 2, knownRatio: 1, defaultLeftoverDays: 1, excludedTagIds: [] }, now, mulberry32(1));
    const links = await shoppingLinks(db, familyId);
    expect(links.categoryIds).toEqual(["groceries"]);
    expect(links.lists.map((l) => l.date)).toEqual(["2026-06-01", "2026-06-04"]);
    const thursday = db.select().from(shoppingLists).all().find((l) => l.shoppingDate === "2026-06-04")!;
    expect(listForTransaction(links, { date: "2026-06-05", categoryId: "groceries" })?.id).toBe(thursday.id);

    // Another family sees none of them.
    const other = makeFamily(db, makeUser(db).id);
    expect((await shoppingLinks(db, other.id)).lists).toEqual([]);
  });
});

describe("the groceries setting", () => {
  it("is set by id or name through PATCH /finance/settings and read back by GET /finance", async () => {
    const handler = createFamilyApi([handleFinance], { db, appUrl: "http://ohana.test", now: () => NOW });
    const token = createToken(db, { userId: editorId, kind: "api" }, NOW).token;
    const call = async (method: string, path: string, body?: unknown) => {
      const res = await handler(
        new Request(`http://ohana.test/api/v1/families/${familyId}${path}`, {
          method,
          headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
          body: body === undefined ? undefined : JSON.stringify(body),
        }),
      );
      return { status: res.status, data: await res.json() };
    };
    expect((await call("GET", "/finance")).data.groceriesCategoryId).toBeNull();
    expect((await call("PATCH", "/finance/settings", { groceriesCategoryId: "Leisure" })).data.groceriesCategoryId).toBe("leisure");
    expect((await shoppingSpend(db, familyId, "2026-11-03")).category?.id).toBe("leisure");
    // Other settings changes keep it.
    await call("PATCH", "/finance/settings", { currency: "CHF" });
    expect((await call("GET", "/finance")).data).toMatchObject({ currency: "CHF", groceriesCategoryId: "leisure" });
    expect((await call("PATCH", "/finance/settings", { groceriesCategoryId: "nope" })).status).toBe(404);
    expect((await call("PATCH", "/finance/settings", { groceriesCategoryId: null })).data.groceriesCategoryId).toBeNull();
    expect((await shoppingSpend(db, familyId, "2026-11-03")).category?.id).toBe("groceries");
  });
});
