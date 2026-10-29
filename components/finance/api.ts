// Client of the finance API (/api/v1/families/{id}/finance/...): family-planner's
// app/src/lib/api.ts (finance calls and types).

import { enc, fam, request } from "@/lib/api/client";

export type CategoryKind = "income" | "expense" | "both";

export interface Category {
  id: string;
  name: string;
  color: string;
  icon: string;
  /** A subcategory has the kind of its top-level category. */
  kind: CategoryKind;
  /** Among its siblings. */
  position: number;
  /** The category it is a subcategory of; null for a top-level one. */
  parentId: string | null;
}

/** A bank account (Konto); its balance is the opening balance plus all its transactions. */
export interface Account {
  id: string;
  name: string;
  color: string;
  icon: string;
  openingCents: number;
  position: number;
  balanceCents: number;
}

export interface Transaction {
  id: string;
  date: string;
  amountCents: number;
  payee: string;
  description: string;
  categoryId: string | null;
  accountId: string | null;
  /** Set on the legs of a transfer (≥ 2 transactions that count once, as their sum). */
  transferId: string | null;
  /** Set on a part of a split booking: the booking's id. A part counts on its own, with its
   *  own category; the booking only with what its parts leave over. */
  splitOf: string | null;
  /** Set on a booking that has parts: how many, and what it still counts itself (its amount
   *  minus the parts' sum, often 0). */
  split: { parts: number; remainderCents: number } | null;
  note: string;
  imported: boolean;
}

/** Two transactions that look like money moved between two of the family's accounts. */
export interface TransferPair {
  out: Transaction;
  in: Transaction;
}

/** An amount per month from lowCents to highCents (the same twice for a single value). */
export interface CentsRange {
  lowCents: number;
  highCents: number;
}

/** A statistic average to compare with (e.g. a statistics office's household spending): ranges
 *  for income, expenses and categories, all per month. */
export interface Benchmark {
  label: string;
  income: CentsRange | null;
  expense: CentsRange | null;
  categories: ({ categoryId: string } & CentsRange)[];
}

export interface FinanceOverview {
  currency: string;
  csvMappings: unknown[];
  /** Not set: null. */
  benchmark: Benchmark | null;
  categories: Category[];
  accounts: Account[];
}

export interface TransactionList {
  transactions: Transaction[];
  total: number;
  incomeCents: number;
  expenseCents: number;
}

export interface FinanceSummary {
  currency: string;
  incomeCents: number;
  expenseCents: number;
  count: number;
  months: { month: string; incomeCents: number; expenseCents: number }[];
  categories: {
    categoryId: string | null;
    incomeCents: number;
    expenseCents: number;
    count: number;
  }[];
}

/** An op for POST /finance/transactions; the response's `inverse` ops undo a request. */
export type TransactionOp = Record<string, unknown> & {
  action: "add" | "update" | "delete" | "link" | "unlink" | "split" | "unsplit";
};

export interface TransactionResult {
  ok: true;
  changed: number;
  added: string[];
  inverse: TransactionOp[];
}

export interface ImportRow {
  date: string;
  amountCents: number;
  payee: string;
  description: string;
}

export interface ImportResult {
  added: number;
  duplicates: number[];
  ids: string[];
  transfers?: number;
  splits?: number;
}

const fin = (id: string) => `${fam(id)}/finance`;

export const financeApi = {
  overview: (id: string) => request<FinanceOverview>("GET", fin(id)),
  clear: (id: string) => request<FinanceOverview>("DELETE", fin(id)),
  settings: (id: string, patch: { currency?: string; csvMappings?: unknown[]; benchmark?: Benchmark | null }) =>
    request<FinanceOverview>("PATCH", `${fin(id)}/settings`, patch),
  addCategory: (id: string, c: Omit<Category, "id" | "position" | "parentId"> & { parentId?: string | null }) =>
    request<Category>("POST", `${fin(id)}/categories`, c),
  updateCategory: (id: string, categoryId: string, patch: Partial<Category>) =>
    request<Category>("PATCH", `${fin(id)}/categories/${enc(categoryId)}`, patch),
  deleteCategory: (id: string, categoryId: string) =>
    request<unknown>("DELETE", `${fin(id)}/categories/${enc(categoryId)}`),
  defaultCategories: (id: string, lang: string) =>
    request<Category[]>("POST", `${fin(id)}/categories/defaults`, { lang }),
  addAccount: (id: string, a: { name: string; color: string; icon?: string; openingCents?: number }) =>
    request<Account>("POST", `${fin(id)}/accounts`, a),
  updateAccount: (id: string, accountId: string, patch: Partial<Omit<Account, "id" | "balanceCents">>) =>
    request<Account>("PATCH", `${fin(id)}/accounts/${enc(accountId)}`, patch),
  /** The accounts with their balances at the end of the day `at`. */
  accountsAt: (id: string, at: string) =>
    request<{ at: string; accounts: Account[] }>("GET", `${fin(id)}/accounts?${new URLSearchParams({ at })}`),
  deleteAccount: (id: string, accountId: string) =>
    request<{ deleted: string }>("DELETE", `${fin(id)}/accounts/${enc(accountId)}`),
  transactions: (id: string, query: Record<string, string>) =>
    request<TransactionList>("GET", `${fin(id)}/transactions?${new URLSearchParams(query)}`),
  changeTransactions: (id: string, ops: TransactionOp[]) =>
    request<TransactionResult>("POST", `${fin(id)}/transactions`, { ops }),
  importTransactions: (id: string, rows: ImportRow[], dryRun = false, accountId?: string, autoTransfers = false) =>
    request<ImportResult>("POST", `${fin(id)}/import`, {
      rows,
      dryRun,
      ...(accountId ? { accountId } : {}),
      ...(autoTransfers ? { autoTransfers } : {}),
    }),
  transferSuggestions: (id: string, query: Record<string, string>) =>
    request<{ pairs: TransferPair[] }>("GET", `${fin(id)}/transfers/suggestions?${new URLSearchParams(query)}`),
  /** Combines the split bookings in the range (all time without one) with their parts, then
   *  every likely transfer into its own group. */
  autoTransfers: (id: string, range: { from?: string; to?: string }) =>
    request<TransactionResult & { linked: number; splits: number }>("POST", `${fin(id)}/transfers/auto`, range),
  summary: (id: string, query: Record<string, string>) =>
    request<FinanceSummary>("GET", `${fin(id)}/summary?${new URLSearchParams(query)}`),
};
