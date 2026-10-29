import { sql } from "drizzle-orm";
import { check, foreignKey, index, integer, primaryKey, sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core";
import { families } from "../schema";

// ---- finance (family-planner's family_settings, finance_categories, finance_accounts and
// transactions). Money is integer cents, negative for money going out; days are YYYY-MM-DD.
// The references inside a family (category, account, parent, booking) are composite foreign
// keys without an action: SQLite can't set just one column of a composite key to null, so
// lib/finance/store.ts moves or clears them before it deletes (family-planner's ON DELETE SET
// NULL (column) and delete_finance_category).

/** Per family: the currency, the saved CSV column mappings and the statistic average. */
export const finSettings = sqliteTable("fin_settings", {
  familyId: text("family_id")
    .primaryKey()
    .references(() => families.id, { onDelete: "cascade" }),
  currency: text("currency").notNull().default("EUR"), // ISO 4217
  /** JSON array of CSV mappings (lib/finance/csv.ts CsvMapping), newest first. */
  csvMappings: text("csv_mappings").notNull().default("[]"),
  /** JSON Benchmark, or null when not set. */
  benchmark: text("benchmark"),
  /** The category of grocery shopping (with its subcategories), for the shopping lists' "spent"
   *  (phase 7). Null: the category named Groceries / Lebensmittel, if there is one. No foreign
   *  key: a deleted category falls back to that default. */
  groceriesCategoryId: text("groceries_category_id"),
});

/** A category (e.g. Groceries); a tree through parent_id, any depth. A subcategory has the kind
 *  of its top-level category. */
export const finCategories = sqliteTable(
  "fin_categories",
  {
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    /** Unique within the family (a slug of the name, e.g. "groceries"). */
    id: text("id").notNull(),
    name: text("name").notNull(),
    color: text("color").notNull(),
    icon: text("icon").notNull().default(""),
    kind: text("kind").notNull().default("expense"), // income | expense | both
    position: integer("position").notNull().default(0), // among its siblings
    parentId: text("parent_id"),
  },
  (t) => ({
    pk: primaryKey({ columns: [t.familyId, t.id] }),
    parent: foreignKey({ columns: [t.familyId, t.parentId], foreignColumns: [t.familyId, t.id] }),
    finCategoriesParentIdx: index("fin_categories_parent_idx").on(t.familyId, t.parentId),
    kind: check("fin_categories_kind", sql`${t.kind} in ('income', 'expense', 'both')`),
    notSelf: check("fin_categories_parent_not_self", sql`${t.parentId} is null or ${t.parentId} <> ${t.id}`),
  }),
);

/** A bank account, cash or a card; its balance is the opening balance plus its transactions. */
export const finAccounts = sqliteTable(
  "fin_accounts",
  {
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    id: text("id").notNull(), // unique within the family
    name: text("name").notNull(),
    color: text("color").notNull(),
    icon: text("icon").notNull().default(""),
    openingCents: integer("opening_cents").notNull().default(0),
    position: integer("position").notNull().default(0),
  },
  (t) => ({ pk: primaryKey({ columns: [t.familyId, t.id] }) }),
);

/** A transaction. Ones sharing a transfer_id are the legs of one transfer between the family's
 *  accounts; split_of makes it a part of another one (a split booking). */
export const finTransactions = sqliteTable(
  "fin_transactions",
  {
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    id: text("id").notNull(), // uuid
    day: text("day").notNull(), // YYYY-MM-DD
    amountCents: integer("amount_cents").notNull(), // negative: money going out
    payee: text("payee").notNull().default(""),
    description: text("description").notNull().default(""),
    categoryId: text("category_id"),
    note: text("note").notNull().default(""),
    /** Set for imported rows, so the same statement isn't imported twice. */
    importHash: text("import_hash"),
    accountId: text("account_id"),
    transferId: text("transfer_id"),
    splitOf: text("split_of"),
    createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
  },
  (t) => ({
    pk: primaryKey({ columns: [t.familyId, t.id] }),
    category: foreignKey({
      columns: [t.familyId, t.categoryId],
      foreignColumns: [finCategories.familyId, finCategories.id],
    }),
    account: foreignKey({
      columns: [t.familyId, t.accountId],
      foreignColumns: [finAccounts.familyId, finAccounts.id],
    }),
    booking: foreignKey({ columns: [t.familyId, t.splitOf], foreignColumns: [t.familyId, t.id] }),
    finTransactionsDayIdx: index("fin_transactions_day_idx").on(t.familyId, t.day),
    finTransactionsImportHashIdx: uniqueIndex("fin_transactions_import_hash_idx")
      .on(t.familyId, t.importHash)
      .where(sql`${t.importHash} is not null`),
    finTransactionsTransferIdx: index("fin_transactions_transfer_idx")
      .on(t.familyId, t.transferId)
      .where(sql`${t.transferId} is not null`),
    finTransactionsSplitIdx: index("fin_transactions_split_idx")
      .on(t.familyId, t.splitOf)
      .where(sql`${t.splitOf} is not null`),
    finTransactionsAccountIdx: index("fin_transactions_account_idx").on(t.familyId, t.accountId),
    finTransactionsCategoryIdx: index("fin_transactions_category_idx").on(t.familyId, t.categoryId),
    amount: check("fin_transactions_amount", sql`abs(${t.amountCents}) <= 100000000000000`),
  }),
);
