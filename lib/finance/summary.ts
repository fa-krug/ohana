// What the family overview shows of the finances: this month's income and expenses (net
// counting, like the finance page), where most of the money went, and the accounts' balance.

import type { Db } from "@/lib/db";
import { categoryTree } from "./category-tree";
import { financeSummary, listAccounts } from "./finance";
import { DrizzleFinanceStore } from "./store";

export interface MonthSummary {
  currency: string;
  /** YYYY-MM */
  month: string;
  incomeCents: number;
  expenseCents: number;
  /** How many items count (a transfer group once). */
  count: number;
  /** The top-level category with the most expenses (its subcategories included), if any;
   *  uncategorized expenses don't count. */
  topExpense: { categoryId: string; name: string; icon: string; color: string; expenseCents: number } | null;
  /** All accounts together now; null without accounts. */
  balanceCents: number | null;
}

function lastDay(month: string): string {
  const [y, m] = month.split("-").map(Number);
  return `${month}-${String(new Date(Date.UTC(y, m, 0)).getUTCDate()).padStart(2, "0")}`;
}

export async function monthSummary(db: Db, familyId: string, today: string): Promise<MonthSummary> {
  const store = new DrizzleFinanceStore(db);
  const month = today.slice(0, 7);
  const [summary, categories, accounts] = await Promise.all([
    financeSummary(store, familyId, `${month}-01`, lastDay(month)),
    store.listCategories(familyId),
    listAccounts(store, familyId),
  ]);
  const tree = categoryTree(categories);
  const byTop = new Map<string | null, number>();
  for (const c of summary.categories) {
    const top = c.categoryId && tree.byId.has(c.categoryId) ? tree.atLevel(c.categoryId, 1).id : null;
    byTop.set(top, (byTop.get(top) ?? 0) + c.expenseCents);
  }
  let topExpense: MonthSummary["topExpense"] = null;
  for (const [id, cents] of byTop) {
    if (!id || cents <= 0 || (topExpense && topExpense.expenseCents >= cents)) continue;
    const c = tree.byId.get(id)!;
    topExpense = { categoryId: id, name: c.name, icon: c.icon, color: c.color, expenseCents: cents };
  }
  return {
    currency: summary.currency,
    month,
    incomeCents: summary.incomeCents,
    expenseCents: summary.expenseCents,
    count: summary.count,
    topExpense,
    balanceCents: accounts.length ? accounts.reduce((sum, a) => sum + a.balanceCents, 0) : null,
  };
}
