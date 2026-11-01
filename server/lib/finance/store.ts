// Storage of the finances: the finance part of family-planner's `Store` interface
// (_shared/store.ts) over Drizzle/SQLite, so finance.ts works on it as it did on Supabase. Rows
// keep family-planner's snake_case shapes. Calls run synchronously (better-sqlite3) and return
// promises to keep its interface; what the source did in one database function (deleting a
// category, the import) runs in one transaction here.

import { and, asc, desc, eq, gte, inArray, isNotNull, isNull, lte, sql } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { finAccounts, finCategories, finSettings, finTransactions } from "@/lib/db/schema";
import { categoryTree } from "./category-tree";

export type CategoryKind = "income" | "expense" | "both";
export const CATEGORY_KINDS: CategoryKind[] = ["income", "expense", "both"];

/** A finance category, e.g. Groceries. */
export interface CategoryRow {
  family_id: string;
  id: string; // unique within the family
  name: string;
  color: string;
  icon: string; // an emoji, or ""
  kind: CategoryKind; // a subcategory has the kind of its top-level category
  position: number; // among its siblings
  /** The category it is a subcategory of; null for a top-level one. */
  parent_id: string | null;
}

/** A finance account (Konto), e.g. the checking account. */
export interface AccountRow {
  family_id: string;
  id: string; // unique within the family
  name: string;
  color: string;
  icon: string; // an emoji, or ""
  opening_cents: number; // the balance before the first transaction
  position: number;
}

export interface TransactionRow {
  family_id: string;
  id: string; // uuid
  day: string;
  amount_cents: number; // negative: money going out
  payee: string;
  description: string;
  category_id: string | null;
  note: string;
  /** Set for imported rows, so the same statement isn't imported twice. */
  import_hash: string | null;
  account_id: string | null;
  /** Transactions sharing one are the legs of a transfer between the family's accounts. */
  transfer_id: string | null;
  /** Set on a part of a split booking: the booking's id (see splits in finance.ts). */
  split_of: string | null;
  created_at: string;
}

/** An amount per month from lowCents to highCents (the same twice for a single value). */
export interface CentsRange {
  lowCents: number;
  highCents: number;
}

/** A statistic average the overview compares the family's months with (e.g. a statistics
 *  office's household spending): ranges for income, expenses and categories, all per month. */
export interface Benchmark {
  label: string;
  income: CentsRange | null;
  expense: CentsRange | null;
  categories: ({ categoryId: string } & CentsRange)[];
}

export interface FinanceSettingsRow {
  family_id: string;
  currency: string; // ISO 4217, e.g. EUR
  csv_mappings: unknown[];
  /** Not set: null. */
  benchmark?: Benchmark | null;
}

/** Everything of the finances, for an import that replaces them. */
export interface FinanceContents {
  categories: CategoryRow[];
  accounts: AccountRow[];
  transactions: TransactionRow[];
  currency: string;
}

export interface FinanceStore {
  getFinanceSettings(familyId: string): Promise<FinanceSettingsRow | null>;
  saveFinanceSettings(row: FinanceSettingsRow): Promise<void>;
  /** Categories ordered by position. */
  listCategories(familyId: string): Promise<CategoryRow[]>;
  upsertCategories(rows: CategoryRow[]): Promise<void>;
  /** Deletes the category; its subcategories and transactions move to its parent (top level:
   *  the subcategories become top-level ones, the transactions uncategorized). */
  deleteCategory(familyId: string, id: string): Promise<void>;
  /** Accounts ordered by position. */
  listAccounts(familyId: string): Promise<AccountRow[]>;
  upsertAccounts(rows: AccountRow[]): Promise<void>;
  /** Deletes the account and its transactions; returns those transactions. Parts of a deleted
   *  booking on other accounts become normal transactions. */
  deleteAccount(familyId: string, id: string): Promise<TransactionRow[]>;
  /** Sum of all transactions (all time, or up to and including the day `until`) per account
   *  id, for the balances. Parts of split bookings don't count: their booking does. */
  accountTotals(familyId: string, until?: string): Promise<Map<string, number>>;
  /** Transactions in the range (all without one), newest first. */
  listTransactions(familyId: string, from?: string, to?: string): Promise<TransactionRow[]>;
  getTransactions(familyId: string, ids: string[]): Promise<TransactionRow[]>;
  /** All legs of the given transfer groups. */
  listTransfers(familyId: string, transferIds: string[]): Promise<TransactionRow[]>;
  /** All transactions that are parts of a split booking. */
  listSplitParts(familyId: string): Promise<TransactionRow[]>;
  /** Inserts or replaces transactions (by id). */
  upsertTransactions(rows: TransactionRow[]): Promise<void>;
  /** Deletes the transactions; parts of a deleted booking become normal transactions. */
  deleteTransactions(familyId: string, ids: string[]): Promise<void>;
  /** Deletes all transactions, accounts, categories and finance settings of the family. */
  clearFinance(familyId: string): Promise<void>;
  /** Which of the hashes imported transactions already have. */
  existingImportHashes(familyId: string, hashes: string[]): Promise<Set<string>>;
}

const CHUNK = 500;

function chunks<T>(list: T[], size = CHUNK): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

type Tx = Pick<Db, "insert" | "update" | "delete" | "select">;

function isKind(v: string): v is CategoryKind {
  return CATEGORY_KINDS.includes(v as CategoryKind);
}

function categoryRow(c: typeof finCategories.$inferSelect): CategoryRow {
  return {
    family_id: c.familyId,
    id: c.id,
    name: c.name,
    color: c.color,
    icon: c.icon,
    kind: isKind(c.kind) ? c.kind : "expense",
    position: c.position,
    parent_id: c.parentId,
  };
}

function accountRow(a: typeof finAccounts.$inferSelect): AccountRow {
  return {
    family_id: a.familyId,
    id: a.id,
    name: a.name,
    color: a.color,
    icon: a.icon,
    opening_cents: a.openingCents,
    position: a.position,
  };
}

function txRow(t: typeof finTransactions.$inferSelect): TransactionRow {
  return {
    family_id: t.familyId,
    id: t.id,
    day: t.day,
    amount_cents: t.amountCents,
    payee: t.payee,
    description: t.description,
    category_id: t.categoryId,
    note: t.note,
    import_hash: t.importHash,
    account_id: t.accountId,
    transfer_id: t.transferId,
    split_of: t.splitOf,
    created_at: t.createdAt.toISOString(),
  };
}

function categoryValues(c: CategoryRow) {
  return {
    familyId: c.family_id,
    id: c.id,
    name: c.name,
    color: c.color,
    icon: c.icon,
    kind: c.kind,
    position: c.position,
    parentId: c.parent_id ?? null,
  };
}

function accountValues(a: AccountRow) {
  return {
    familyId: a.family_id,
    id: a.id,
    name: a.name,
    color: a.color,
    icon: a.icon,
    openingCents: a.opening_cents,
    position: a.position,
  };
}

function txValues(t: TransactionRow) {
  const created = new Date(t.created_at);
  return {
    familyId: t.family_id,
    id: t.id,
    day: t.day,
    amountCents: t.amount_cents,
    payee: t.payee,
    description: t.description,
    categoryId: t.category_id,
    note: t.note,
    importHash: t.import_hash,
    accountId: t.account_id,
    transferId: t.transfer_id,
    splitOf: t.split_of,
    createdAt: Number.isNaN(created.getTime()) ? new Date() : created,
  };
}

/** Bookings before their parts, so a part's foreign key never points ahead. */
function bookingsFirst(rows: TransactionRow[]) {
  return [...rows].sort((a, b) => Number(!!a.split_of) - Number(!!b.split_of));
}

/** Parents before their subcategories (tree order), for the same reason. */
function parentsFirst(rows: CategoryRow[]) {
  const order = categoryTree(rows).ordered;
  return order.length === rows.length ? order : rows;
}

/** Inserts or updates the categories. A new parent that comes later in `rows` is inserted
 *  first: the rows go parents first. */
function upsertCategoriesIn(tx: Tx, rows: CategoryRow[]) {
  for (const c of parentsFirst(rows)) {
    const v = categoryValues(c);
    tx.insert(finCategories)
      .values(v)
      .onConflictDoUpdate({
        target: [finCategories.familyId, finCategories.id],
        set: { name: v.name, color: v.color, icon: v.icon, kind: v.kind, position: v.position, parentId: v.parentId },
      })
      .run();
  }
}

function upsertTransactionsIn(tx: Tx, rows: TransactionRow[]) {
  for (const t of bookingsFirst(rows)) {
    const v = txValues(t);
    const { familyId: _f, id: _i, ...set } = v;
    tx.insert(finTransactions)
      .values(v)
      .onConflictDoUpdate({ target: [finTransactions.familyId, finTransactions.id], set })
      .run();
  }
}

/** Clears split_of of the parts of `ids` that aren't in `ids` themselves (family-planner's
 *  ON DELETE SET NULL (split_of)). */
function orphanParts(tx: Tx, familyId: string, ids: string[]) {
  for (const part of chunks(ids)) {
    tx.update(finTransactions)
      .set({ splitOf: null })
      .where(and(eq(finTransactions.familyId, familyId), inArray(finTransactions.splitOf, part)))
      .run();
  }
}

function deleteAll(tx: Tx, familyId: string) {
  // One statement each: the foreign keys inside a table are checked at its end.
  tx.delete(finTransactions).where(eq(finTransactions.familyId, familyId)).run();
  tx.delete(finAccounts).where(eq(finAccounts.familyId, familyId)).run();
  tx.delete(finCategories).where(eq(finCategories.familyId, familyId)).run();
}

/** Replaces all finances of the family within the caller's transaction (the export file's
 *  import): categories, accounts, transactions and the currency; the CSV mappings and the
 *  statistic average stay. */
export function replaceFinance(tx: Tx, familyId: string, finance: FinanceContents) {
  deleteAll(tx, familyId);
  for (const part of chunks(parentsFirst(finance.categories))) {
    tx.insert(finCategories)
      .values(part.map((c) => categoryValues({ ...c, family_id: familyId })))
      .run();
  }
  for (const part of chunks(finance.accounts)) {
    tx.insert(finAccounts)
      .values(part.map((a) => accountValues({ ...a, family_id: familyId })))
      .run();
  }
  for (const part of chunks(bookingsFirst(finance.transactions))) {
    tx.insert(finTransactions)
      .values(part.map((t) => txValues({ ...t, family_id: familyId })))
      .run();
  }
  tx.insert(finSettings)
    .values({ familyId, currency: finance.currency })
    .onConflictDoUpdate({ target: finSettings.familyId, set: { currency: finance.currency } })
    .run();
}

/** A new family's default categories (within the caller's transaction). */
export function insertCategories(tx: Tx, rows: CategoryRow[]) {
  if (rows.length) tx.insert(finCategories).values(parentsFirst(rows).map(categoryValues)).run();
}

function parseJson<T>(text: string | null, fallback: T): T {
  if (!text) return fallback;
  try {
    return JSON.parse(text) as T;
  } catch {
    return fallback;
  }
}

/** The finance store over Ohana's database. */
export class DrizzleFinanceStore implements FinanceStore {
  constructor(private db: Db) {}

  async getFinanceSettings(familyId: string) {
    const row = this.db.select().from(finSettings).where(eq(finSettings.familyId, familyId)).get();
    if (!row) return null;
    return {
      family_id: row.familyId,
      currency: row.currency,
      csv_mappings: parseJson<unknown[]>(row.csvMappings, []),
      benchmark: parseJson<Benchmark | null>(row.benchmark, null),
    };
  }

  async saveFinanceSettings(row: FinanceSettingsRow) {
    const values = {
      currency: row.currency,
      csvMappings: JSON.stringify(row.csv_mappings ?? []),
      benchmark: row.benchmark ? JSON.stringify(row.benchmark) : null,
    };
    this.db
      .insert(finSettings)
      .values({ familyId: row.family_id, ...values })
      .onConflictDoUpdate({ target: finSettings.familyId, set: values })
      .run();
  }

  async listCategories(familyId: string) {
    return this.db
      .select()
      .from(finCategories)
      .where(eq(finCategories.familyId, familyId))
      .orderBy(asc(finCategories.position), asc(finCategories.id))
      .all()
      .map(categoryRow);
  }

  async upsertCategories(rows: CategoryRow[]) {
    if (!rows.length) return;
    this.db.transaction((tx) => upsertCategoriesIn(tx, rows));
  }

  async deleteCategory(familyId: string, id: string) {
    // In one transaction: subcategories and transactions move to the parent first.
    this.db.transaction((tx) => {
      const current = tx
        .select({ parentId: finCategories.parentId })
        .from(finCategories)
        .where(and(eq(finCategories.familyId, familyId), eq(finCategories.id, id)))
        .get();
      if (!current) return;
      const parent = current.parentId ?? null;
      tx.update(finCategories)
        .set({ parentId: parent })
        .where(and(eq(finCategories.familyId, familyId), eq(finCategories.parentId, id)))
        .run();
      tx.update(finTransactions)
        .set({ categoryId: parent })
        .where(and(eq(finTransactions.familyId, familyId), eq(finTransactions.categoryId, id)))
        .run();
      tx.delete(finCategories)
        .where(and(eq(finCategories.familyId, familyId), eq(finCategories.id, id)))
        .run();
    });
  }

  async listAccounts(familyId: string) {
    return this.db
      .select()
      .from(finAccounts)
      .where(eq(finAccounts.familyId, familyId))
      .orderBy(asc(finAccounts.position), asc(finAccounts.id))
      .all()
      .map(accountRow);
  }

  async upsertAccounts(rows: AccountRow[]) {
    if (!rows.length) return;
    this.db.transaction((tx) => {
      for (const a of rows) {
        const v = accountValues(a);
        tx.insert(finAccounts)
          .values(v)
          .onConflictDoUpdate({
            target: [finAccounts.familyId, finAccounts.id],
            set: { name: v.name, color: v.color, icon: v.icon, openingCents: v.openingCents, position: v.position },
          })
          .run();
      }
    });
  }

  async deleteAccount(familyId: string, id: string) {
    return this.db.transaction((tx) => {
      const gone = tx
        .select()
        .from(finTransactions)
        .where(and(eq(finTransactions.familyId, familyId), eq(finTransactions.accountId, id)))
        .all()
        .map(txRow);
      orphanParts(
        tx,
        familyId,
        gone.map((t) => t.id),
      );
      tx.delete(finTransactions)
        .where(and(eq(finTransactions.familyId, familyId), eq(finTransactions.accountId, id)))
        .run();
      tx.delete(finAccounts)
        .where(and(eq(finAccounts.familyId, familyId), eq(finAccounts.id, id)))
        .run();
      return gone;
    });
  }

  async accountTotals(familyId: string, until?: string) {
    const rows = this.db
      .select({ accountId: finTransactions.accountId, total: sql<number>`sum(${finTransactions.amountCents})` })
      .from(finTransactions)
      .where(
        and(
          eq(finTransactions.familyId, familyId),
          isNotNull(finTransactions.accountId),
          isNull(finTransactions.splitOf),
          until ? lte(finTransactions.day, until) : undefined,
        ),
      )
      .groupBy(finTransactions.accountId)
      .all();
    return new Map(rows.map((r) => [r.accountId!, Number(r.total)]));
  }

  async listTransactions(familyId: string, from?: string, to?: string) {
    // Newest first; within a day the last created first, and those created at once (an
    // import, say) in the order they were added, like family-planner's memory store.
    return this.db
      .select()
      .from(finTransactions)
      .where(
        and(
          eq(finTransactions.familyId, familyId),
          from ? gte(finTransactions.day, from) : undefined,
          to ? lte(finTransactions.day, to) : undefined,
        ),
      )
      .orderBy(desc(finTransactions.day), desc(finTransactions.createdAt), asc(sql`${finTransactions}.rowid`))
      .all()
      .map(txRow);
  }

  async getTransactions(familyId: string, ids: string[]) {
    const out: TransactionRow[] = [];
    for (const part of chunks([...new Set(ids)])) {
      out.push(
        ...this.db
          .select()
          .from(finTransactions)
          .where(and(eq(finTransactions.familyId, familyId), inArray(finTransactions.id, part)))
          .all()
          .map(txRow),
      );
    }
    // In the order asked for, like the source's stores.
    const byId = new Map(out.map((t) => [t.id, t]));
    return [...new Set(ids)].flatMap((id) => (byId.has(id) ? [byId.get(id)!] : []));
  }

  async listTransfers(familyId: string, transferIds: string[]) {
    const out: TransactionRow[] = [];
    for (const part of chunks(transferIds)) {
      out.push(
        ...this.db
          .select()
          .from(finTransactions)
          .where(and(eq(finTransactions.familyId, familyId), inArray(finTransactions.transferId, part)))
          .orderBy(asc(finTransactions.id))
          .all()
          .map(txRow),
      );
    }
    return out;
  }

  async listSplitParts(familyId: string) {
    return this.db
      .select()
      .from(finTransactions)
      .where(and(eq(finTransactions.familyId, familyId), isNotNull(finTransactions.splitOf)))
      .orderBy(asc(finTransactions.id))
      .all()
      .map(txRow);
  }

  async upsertTransactions(rows: TransactionRow[]) {
    if (!rows.length) return;
    this.db.transaction((tx) => upsertTransactionsIn(tx, rows));
  }

  async deleteTransactions(familyId: string, ids: string[]) {
    if (!ids.length) return;
    this.db.transaction((tx) => {
      // Parts of a deleted booking stay, as normal transactions.
      orphanParts(tx, familyId, ids);
      for (const part of chunks(ids)) {
        tx.delete(finTransactions)
          .where(and(eq(finTransactions.familyId, familyId), inArray(finTransactions.id, part)))
          .run();
      }
    });
  }

  async clearFinance(familyId: string) {
    this.db.transaction((tx) => {
      deleteAll(tx, familyId);
      tx.delete(finSettings).where(eq(finSettings.familyId, familyId)).run();
    });
  }

  async existingImportHashes(familyId: string, hashes: string[]) {
    const found = new Set<string>();
    for (const part of chunks(hashes)) {
      for (const r of this.db
        .select({ hash: finTransactions.importHash })
        .from(finTransactions)
        .where(and(eq(finTransactions.familyId, familyId), inArray(finTransactions.importHash, part)))
        .all()) {
        if (r.hash) found.add(r.hash);
      }
    }
    return found;
  }
}
