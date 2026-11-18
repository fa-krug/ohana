// Which way each category is usually used: how many of its own transactions brought money in and
// how many took money out. GET /finance gives them with the categories (inCount / outCount), so
// the app puts the categories a new transaction's way usually goes first.

import { and, eq, isNotNull, sql } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { finTransactions } from "@/lib/db/schema";

/** Per category id: the number of its own transactions with money in and with money out. */
export function categoryCounts(db: Db, familyId: string): Map<string, { in: number; out: number }> {
  const rows = db
    .select({
      id: finTransactions.categoryId,
      in: sql<number>`sum(${finTransactions.amountCents} > 0)`,
      out: sql<number>`sum(${finTransactions.amountCents} < 0)`,
    })
    .from(finTransactions)
    .where(and(eq(finTransactions.familyId, familyId), isNotNull(finTransactions.categoryId)))
    .groupBy(finTransactions.categoryId)
    .all();
  return new Map(rows.map((r) => [r.id!, { in: Number(r.in), out: Number(r.out) }]));
}
