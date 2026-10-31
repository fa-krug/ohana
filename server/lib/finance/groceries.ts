// Meals → Finance (phase 7), read-only links between a shopping list and the money spent on
// that shopping trip: the family's transactions in its groceries category (with its
// subcategories) on the list's shopping day ± 1 day. The groceries category is a finance
// setting (Settings → Finance); by default the category named Groceries / Lebensmittel. No
// money logic of its own: the totals are the finance module's net counting.

import { and, asc, eq, isNotNull } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { mealPlans, planIterations, shoppingLists } from "@/lib/db/schema";
import { addDays } from "@/lib/calendar/dates";
import { categoryTree } from "./category-tree";
import { findTransactions, publicTransaction } from "./finance";
import { SHOPPING_SLACK_DAYS, type ShoppingLinks } from "./groceries-links";
import { type CategoryRow, DrizzleFinanceStore } from "./store";

export { SHOPPING_SLACK_DAYS, type ShoppingLinks, listForTransaction } from "./groceries-links";

const DEFAULT_NAMES = ["groceries", "lebensmittel"];

/** The groceries category: the configured one if it still exists, else the category with the
 *  id "groceries" or named Groceries / Lebensmittel (top level first); null without one. */
export function groceriesCategory(categories: CategoryRow[], configuredId: string | null | undefined): CategoryRow | null {
  const configured = configuredId ? categories.find((c) => c.id === configuredId) : undefined;
  if (configured) return configured;
  const candidates = categories.filter(
    (c) => c.id === "groceries" || DEFAULT_NAMES.includes(c.name.trim().toLowerCase()),
  );
  candidates.sort((a, b) => Number(!!a.parent_id) - Number(!!b.parent_id) || a.position - b.position);
  return candidates[0] ?? null;
}

export async function loadGroceries(db: Db, familyId: string) {
  const store = new DrizzleFinanceStore(db);
  const [settings, categories] = await Promise.all([store.getFinanceSettings(familyId), store.listCategories(familyId)]);
  const category = groceriesCategory(categories, settings?.groceries_category_id);
  return {
    store,
    currency: settings?.currency ?? "EUR",
    category,
    /** The category and its subcategories. */
    ids: category ? categoryTree(categories).subtree(category.id) : new Set<string>(),
  };
}

export interface ShoppingSpend {
  currency: string;
  category: { id: string; name: string; icon: string; color: string } | null;
  from: string;
  to: string;
  transactions: { id: string; date: string; payee: string; description: string; amountCents: number }[];
  /** What was spent (expenses minus refunds, net counting); positive. */
  totalCents: number;
}

/** The groceries transactions around a shopping day. */
export async function shoppingSpend(db: Db, familyId: string, shoppingDate: string): Promise<ShoppingSpend> {
  const { store, currency, category } = await loadGroceries(db, familyId);
  const from = addDays(shoppingDate, -SHOPPING_SLACK_DAYS);
  const to = addDays(shoppingDate, SHOPPING_SLACK_DAYS);
  if (!category) return { currency, category: null, from, to, transactions: [], totalCents: 0 };
  const { rows, links, incomeCents, expenseCents } = await findTransactions(
    store,
    familyId,
    new URLSearchParams({ from, to, category: category.id }),
  );
  return {
    currency,
    category: { id: category.id, name: category.name, icon: category.icon, color: category.color },
    from,
    to,
    transactions: rows.map((t) => {
      const p = publicTransaction(t, links);
      return { id: p.id, date: p.date, payee: p.payee, description: p.description, amountCents: p.amountCents };
    }),
    totalCents: expenseCents - incomeCents,
  };
}

/** The groceries categories and the family's shopping days (for the finance page). */
export async function shoppingLinks(db: Db, familyId: string): Promise<ShoppingLinks> {
  const { ids } = await loadGroceries(db, familyId);
  if (!ids.size) return { categoryIds: [], lists: [] };
  const lists = db
    .select({ id: shoppingLists.id, date: shoppingLists.shoppingDate })
    .from(shoppingLists)
    .innerJoin(planIterations, eq(planIterations.id, shoppingLists.iterationId))
    .innerJoin(mealPlans, eq(mealPlans.id, planIterations.mealPlanId))
    .where(and(eq(mealPlans.familyId, familyId), isNotNull(shoppingLists.shoppingDate)))
    .orderBy(asc(shoppingLists.shoppingDate))
    .all()
    .map((l) => ({ id: l.id, date: l.date! }));
  return { categoryIds: [...ids], lists };
}
