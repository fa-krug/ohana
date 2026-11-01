// Finances: categories, accounts, a transactions log (entered by hand or imported from bank CSV
// files) and summaries per month and category (ported from family-planner's _shared/finance.ts;
// the routes keep its paths and JSON shapes). Amounts are integer cents, negative for money
// going out. Transactions sharing a transfer id are the legs of one transfer between the
// family's own accounts: totals count such a group once, by its net. A transaction can also be
// a part of another one, its booking (a split booking, like an Amazon "Splitbuchung" whose order
// lines the bank lists too): totals count the parts and what is left of the booking (see
// netItems). Viewers and editors read, editors change.

import type { Ctx } from "@/lib/api/family-api";
import { cleanName, HttpError, json, objectOf, readBody, slug } from "@/lib/api/http";
import { addDays, diffDays, isValidDate } from "@/lib/calendar/dates";
import type { Lang } from "@/lib/i18n/config";
import { categoryTree, PATH_SEPARATOR } from "./category-tree";
import {
  type AccountRow,
  type Benchmark,
  CATEGORY_KINDS,
  type CategoryKind,
  type CategoryRow,
  type CentsRange,
  type FinanceContents,
  type FinanceSettingsRow,
  type FinanceStore as Store,
  type TransactionRow,
} from "./store";

export const MAX_CATEGORIES = 250;
export const MAX_ACCOUNTS = 50;
const MAX_OPS = 2000;
const MAX_IMPORT_ROWS = 5000;
const MAX_IMPORT_TRANSACTIONS = 100_000; // in an export file
const MAX_AMOUNT = 100_000_000_000_000; // cents
const MAX_LIST = 1000;
const MAX_MAPPINGS = 20;
const MAX_BENCHMARK_LABEL = 120;
const MAX_SUGGESTIONS = 200;
const TRANSFER_DAYS = 4; // how far apart the two legs of a suggested transfer may be
const SPLIT_RE = /split-?buchung/i; // how banks mark a booking whose parts they list as well
// An order line's order number, which the bank's booking of the order names too.
const ORDER_RE = /\bbestell(?:ung)?\s*(?:nr\.?|nummer)\s*:?\s*([\p{L}\p{N}]+(?:-[\p{L}\p{N}]+)*)/iu;
const MAX_SPLIT_SEARCH = 16; // parts that a booking's exact sum is searched among
const COLOR_RE = /^#[0-9a-fA-F]{6}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CATEGORY_ID_RE = /^[a-z0-9][a-z0-9-]{0,47}$/;

const DEFAULT_CATEGORIES: {
  id: string;
  icon: string;
  color: string;
  kind: CategoryKind;
  name: Record<Lang, string>;
}[] = [
  {
    id: "salary",
    icon: "💼",
    color: "#22c55e",
    kind: "income",
    name: { en: "Salary", de: "Gehalt" },
  },
  {
    id: "other-income",
    icon: "💰",
    color: "#14b8a6",
    kind: "income",
    name: { en: "Other income", de: "Sonstige Einnahmen" },
  },
  {
    id: "groceries",
    icon: "🛒",
    color: "#f97316",
    kind: "expense",
    name: { en: "Groceries", de: "Lebensmittel" },
  },
  {
    id: "housing",
    icon: "🏠",
    color: "#8b5cf6",
    kind: "expense",
    name: { en: "Housing", de: "Wohnen" },
  },
  {
    id: "utilities",
    icon: "💡",
    color: "#eab308",
    kind: "expense",
    name: { en: "Utilities", de: "Nebenkosten" },
  },
  {
    id: "mobility",
    icon: "🚗",
    color: "#3b82f6",
    kind: "expense",
    name: { en: "Mobility", de: "Mobilität" },
  },
  {
    id: "insurance",
    icon: "🛡️",
    color: "#64748b",
    kind: "expense",
    name: { en: "Insurance", de: "Versicherungen" },
  },
  {
    id: "health",
    icon: "🩺",
    color: "#ef4444",
    kind: "expense",
    name: { en: "Health", de: "Gesundheit" },
  },
  { id: "kids", icon: "🧸", color: "#ec4899", kind: "expense", name: { en: "Kids", de: "Kinder" } },
  {
    id: "leisure",
    icon: "🎉",
    color: "#a855f7",
    kind: "expense",
    name: { en: "Leisure", de: "Freizeit" },
  },
  {
    id: "vacation",
    icon: "🏖️",
    color: "#06b6d4",
    kind: "expense",
    name: { en: "Vacation", de: "Urlaub" },
  },
  {
    id: "shopping",
    icon: "🛍️",
    color: "#84cc16",
    kind: "expense",
    name: { en: "Shopping", de: "Einkäufe" },
  },
  {
    id: "other",
    icon: "📦",
    color: "#94a3b8",
    kind: "both",
    name: { en: "Other", de: "Sonstiges" },
  },
];

export function defaultCategories(familyId: string, lang: Lang): CategoryRow[] {
  return DEFAULT_CATEGORIES.map((c, position) => ({
    family_id: familyId,
    id: c.id,
    name: c.name[lang],
    color: c.color,
    icon: c.icon,
    kind: c.kind,
    position,
    parent_id: null,
  }));
}

// ------------------------------------------------------------------ validation

function text(v: unknown, field: string, max: number): string {
  if (v === undefined || v === null) return "";
  if (typeof v !== "string") throw new HttpError(400, `${field} must be a string`);
  const s = v.trim();
  if (s.length > max) throw new HttpError(400, `${field} is too long (max. ${max})`);
  return s;
}

function cleanColor(v: unknown): string {
  if (typeof v !== "string" || !COLOR_RE.test(v)) {
    throw new HttpError(400, "color must look like #22c55e");
  }
  return v.toLowerCase();
}

function cleanKind(v: unknown): CategoryKind {
  if (v === undefined) return "expense";
  if (!CATEGORY_KINDS.includes(v as CategoryKind)) {
    throw new HttpError(400, `kind must be one of ${CATEGORY_KINDS.join(", ")}`);
  }
  return v as CategoryKind;
}

function cleanDate(v: unknown, field = "date"): string {
  if (!isValidDate(v)) throw new HttpError(400, `${field} must be YYYY-MM-DD`);
  return v as string;
}

function cleanAmount(v: unknown, field = "amountCents"): number {
  if (typeof v !== "number" || !Number.isInteger(v) || Math.abs(v) > MAX_AMOUNT) {
    throw new HttpError(400, `${field} must be a whole number of cents`);
  }
  return v;
}

/** A transfer id or a booking's id: a uuid; null / "" clears it. */
function cleanUuid(v: unknown, field = "transferId"): string | null {
  if (v === null || v === "" || v === undefined) return null;
  if (typeof v !== "string" || !UUID_RE.test(v)) {
    throw new HttpError(400, `${field} must be a uuid`);
  }
  return v;
}

function cleanCurrency(v: unknown): string {
  if (typeof v !== "string" || !/^[A-Z]{3}$/.test(v)) {
    throw new HttpError(400, "currency must be an ISO 4217 code like EUR");
  }
  return v;
}

/** A category reference by id, (case-insensitive) path ("Food > Groceries") or name; null /
 *  "" clears it. A name that several categories have needs the path. */
function resolveCategory(categories: CategoryRow[], ref: unknown): string | null {
  if (ref === null || ref === "" || ref === undefined) return null;
  if (typeof ref !== "string") throw new HttpError(400, "categoryId must be a string");
  const byId = categories.find((c) => c.id === ref);
  if (byId) return byId.id;
  const tree = categoryTree(categories);
  const want = ref.split(">").map((n) => n.trim().toLowerCase()).join(PATH_SEPARATOR);
  const byPath = ref.includes(">")
    ? categories.filter((c) => tree.path(c.id).toLowerCase() === want)
    : [];
  const named = byPath.length
    ? byPath
    : categories.filter((c) => c.name.toLowerCase() === ref.trim().toLowerCase());
  if (named.length > 1) {
    throw new HttpError(
      400,
      `Several categories are called "${ref}": use the path (${
        named.map((c) => `"${tree.path(c.id)}"`).join(", ")
      })`,
    );
  }
  if (!named.length) throw new HttpError(404, `Unknown category "${ref}"`);
  return named[0].id;
}

/** A category by id or (case-insensitive) name. */
export function findCategory(categories: CategoryRow[], ref: unknown): CategoryRow {
  const id = resolveCategory(categories, ref);
  const c = categories.find((c) => c.id === id);
  if (!c) throw new HttpError(404, `Unknown category "${ref}"`);
  return c;
}

/** The kind of a top-level category: a subcategory has its top-level category's. */
function kindUnder(categories: CategoryRow[], parentId: string | null, kind: CategoryKind) {
  return parentId ? categoryTree(categories).atLevel(parentId, 1).kind : kind;
}

/** A new category from {name, color, icon, kind, parentId (id, name or path; none: top
 *  level)}, added after the family's others. A subcategory gets the kind of its parent. */
export function newCategory(
  familyId: string,
  categories: CategoryRow[],
  body: Record<string, unknown>,
): CategoryRow {
  if (categories.length >= MAX_CATEGORIES) throw new HttpError(400, "Too many categories");
  const name = cleanName(body.name);
  const parent = resolveCategory(categories, body.parentId);
  return {
    family_id: familyId,
    id: uniqueId(slug(name), new Set(categories.map((c) => c.id))),
    name,
    color: cleanColor(body.color),
    icon: text(body.icon, "icon", 16),
    kind: kindUnder(categories, parent, cleanKind(body.kind)),
    position: categories.reduce((m, c) => Math.max(m, c.position + 1), 0),
    parent_id: parent,
  };
}

/**
 * The category with any of {name, color, icon, kind, position, parentId} changed, first, and
 * its subcategories whose kind changes with it. parentId (id, name or path; null / "": top
 * level) moves it with its subcategories, to the end of its new siblings unless position is
 * given; not into itself or one of its subcategories. Only a top-level category's kind can be
 * set; a subcategory has its top-level category's.
 */
export function changedCategories(
  categories: CategoryRow[],
  current: CategoryRow,
  body: Record<string, unknown>,
): CategoryRow[] {
  const next = { ...current };
  if (body.name !== undefined) next.name = cleanName(body.name);
  if (body.color !== undefined) next.color = cleanColor(body.color);
  if (body.icon !== undefined) next.icon = text(body.icon, "icon", 16);
  const tree = categoryTree(categories);
  if (body.parentId !== undefined) {
    const parent = resolveCategory(categories, body.parentId);
    if (parent && tree.subtree(current.id).has(parent)) {
      throw new HttpError(400, "A category can't go into itself or one of its subcategories");
    }
    if (parent !== (current.parent_id ?? null)) {
      next.parent_id = parent;
      next.position = categories.reduce((m, c) => Math.max(m, c.position + 1), 0);
    }
  }
  if (body.position !== undefined) {
    if (!Number.isInteger(body.position)) {
      throw new HttpError(400, "position must be an integer");
    }
    next.position = body.position as number;
  }
  const kind = body.kind === undefined ? current.kind : cleanKind(body.kind);
  next.kind = kindUnder(categories, next.parent_id ?? null, kind);
  const out = [next];
  for (const id of tree.subtree(current.id)) {
    const c = tree.byId.get(id)!;
    if (id !== current.id && c.kind !== next.kind) out.push({ ...c, kind: next.kind });
  }
  return out;
}

/** An account reference by id or (case-insensitive) name; null / "" clears it. */
function resolveAccount(accounts: AccountRow[], ref: unknown): string | null {
  if (ref === null || ref === "" || ref === undefined) return null;
  if (typeof ref !== "string") throw new HttpError(400, "accountId must be a string");
  const a = accounts.find((a) => a.id === ref) ??
    accounts.find((a) => a.name.toLowerCase() === ref.trim().toLowerCase());
  if (!a) throw new HttpError(404, `Unknown account "${ref}"`);
  return a.id;
}

function uniqueId(base: string, taken: Set<string>, fallback = "category"): string {
  base ||= fallback;
  let id = base;
  for (let i = 2; taken.has(id); i++) id = `${base}-${i}`;
  return id;
}

// ------------------------------------------------------------------ public shapes

export function publicCategory(c: CategoryRow) {
  return {
    id: c.id,
    name: c.name,
    color: c.color,
    icon: c.icon,
    kind: c.kind,
    position: c.position,
    parentId: c.parent_id ?? null,
  };
}

/** An account with its balance: the opening balance plus all of its transactions. */
export function publicAccount(a: AccountRow, totals: Map<string, number>) {
  return {
    id: a.id,
    name: a.name,
    color: a.color,
    icon: a.icon,
    openingCents: a.opening_cents,
    position: a.position,
    balanceCents: a.opening_cents + (totals.get(a.id) ?? 0),
  };
}

/** The accounts with their balances: now, or at the end of the day `at`. */
export async function listAccounts(store: Store, familyId: string, at?: string) {
  const [accounts, totals] = await Promise.all([
    store.listAccounts(familyId),
    store.accountTotals(familyId, at),
  ]);
  return accounts.map((a) => publicAccount(a, totals));
}

/** With `links`, transferId is only set for legs of groups with at least two legs, and `split`
 *  tells a booking's parts and remainder; without them (export), transferId is the stored one. */
export function publicTransaction(t: TransactionRow, links?: Links) {
  const parts = links?.splits.get(t.id);
  return {
    id: t.id,
    date: t.day,
    amountCents: t.amount_cents,
    payee: t.payee,
    description: t.description,
    categoryId: t.category_id,
    accountId: t.account_id,
    transferId: links && !groupOf(t, links.groups) ? null : t.transfer_id,
    splitOf: t.split_of,
    split: parts ? { parts: parts.length, remainderCents: remainderOf(t, parts) } : null,
    note: t.note,
    imported: !!t.import_hash,
  };
}

function settingsOf(familyId: string, row: FinanceSettingsRow | null): FinanceSettingsRow {
  return row ?? { family_id: familyId, currency: "EUR", csv_mappings: [], benchmark: null };
}

/** A range per month from a number (a single value) or {lowCents, highCents} (one of them is
 *  enough for a single value); null when none is given. Not negative, low not above high. */
function cleanCentsRange(v: unknown, field: string): CentsRange | null {
  if (v === null || v === undefined || v === "") return null;
  const cents = (n: unknown, name: string) => {
    if (n === null || n === undefined) return null;
    const c = cleanAmount(n, name);
    if (c < 0) throw new HttpError(400, `${name} must not be negative`);
    return c;
  };
  if (typeof v === "number") {
    const n = cents(v, field)!;
    return { lowCents: n, highCents: n };
  }
  const r = objectOf(v, field);
  const low = cents(r.lowCents, `${field}.lowCents`);
  const high = cents(r.highCents, `${field}.highCents`);
  if (low === null && high === null) return null;
  if (low !== null && high !== null && low > high) {
    throw new HttpError(400, `${field}.lowCents must not be above highCents`);
  }
  return { lowCents: low ?? high!, highCents: high ?? low! };
}

/**
 * A statistic average from {label, income, expense, categories: [{categoryId (id, name or
 * path), lowCents, highCents}]}: amounts per month, each a range {lowCents, highCents} or a
 * single value (a number, or a category's `cents`). Null (or one without any amount) clears it.
 * A category given twice keeps its last range.
 */
export function cleanBenchmark(raw: unknown, categories: CategoryRow[]): Benchmark | null {
  if (raw === null) return null;
  const b = objectOf(raw, "benchmark");
  if (b.label !== undefined && typeof b.label !== "string") {
    throw new HttpError(400, "benchmark.label must be a string");
  }
  if (b.categories !== undefined && b.categories !== null && !Array.isArray(b.categories)) {
    throw new HttpError(400, "benchmark.categories must be an array");
  }
  const byCategory = new Map<string, CentsRange>();
  for (const raw of (b.categories ?? []) as unknown[]) {
    const c = objectOf(raw, "Each benchmark category");
    const id = findCategory(categories, c.categoryId ?? c.category).id;
    const range = cleanCentsRange(
      c.cents ?? { lowCents: c.lowCents, highCents: c.highCents },
      "benchmark.categories",
    );
    if (range) byCategory.set(id, range);
    else byCategory.delete(id);
  }
  const out: Benchmark = {
    label: ((b.label as string | undefined) ?? "").trim().slice(0, MAX_BENCHMARK_LABEL),
    income: cleanCentsRange(b.income, "benchmark.income"),
    expense: cleanCentsRange(b.expense, "benchmark.expense"),
    categories: [...byCategory].map(([categoryId, range]) => ({ categoryId, ...range })),
  };
  return out.income || out.expense || out.categories.length ? out : null;
}

/** The statistic average without categories that are gone since. */
export function benchmarkOf(settings: FinanceSettingsRow | null, categories: CategoryRow[]) {
  const b = settings?.benchmark;
  if (!b) return null;
  const ids = new Set(categories.map((c) => c.id));
  return { ...b, categories: b.categories.filter((c) => ids.has(c.categoryId)) };
}

// ------------------------------------------------------------------ export / import

/** The finances for an export file. */
export async function exportFinance(store: Store, familyId: string) {
  const [settings, categories, accounts, transactions] = await Promise.all([
    store.getFinanceSettings(familyId),
    store.listCategories(familyId),
    store.listAccounts(familyId),
    store.listTransactions(familyId),
  ]);
  return {
    currency: settingsOf(familyId, settings).currency,
    categories: categories.map(publicCategory),
    accounts: accounts.map(({ family_id: _, opening_cents, ...a }) => ({
      id: a.id,
      name: a.name,
      color: a.color,
      icon: a.icon,
      openingCents: opening_cents,
      position: a.position,
    })),
    transactions: transactions.map((t) => ({
      ...publicTransaction(t),
      importHash: t.import_hash,
    })),
  };
}

/** Validates the finances of an export file; the rows get `familyId`. Files from before
 *  accounts have none. */
export function parseFinanceImport(raw: unknown, familyId: string): FinanceContents {
  const f = objectOf(raw, "finance");
  if (!Array.isArray(f.categories)) throw new HttpError(400, "finance.categories must be an array");
  if (!Array.isArray(f.transactions)) {
    throw new HttpError(400, "finance.transactions must be an array");
  }
  if (f.categories.length > MAX_CATEGORIES) throw new HttpError(400, "Too many categories");
  if (f.transactions.length > MAX_IMPORT_TRANSACTIONS) {
    throw new HttpError(400, "Too many transactions");
  }
  const ids = new Set<string>();
  const categories = f.categories.map((raw: unknown, i: number): CategoryRow => {
    const c = objectOf(raw, "Each category");
    if (typeof c.id !== "string" || !CATEGORY_ID_RE.test(c.id) || ids.has(c.id)) {
      throw new HttpError(400, `Invalid category id "${c.id}"`);
    }
    ids.add(c.id);
    return {
      family_id: familyId,
      id: c.id,
      name: cleanName(c.name),
      color: cleanColor(c.color),
      icon: text(c.icon, "icon", 16),
      kind: cleanKind(c.kind),
      position: Number.isInteger(c.position) ? c.position as number : i,
      parent_id: c.parentId === undefined || c.parentId === null ? null : String(c.parentId),
    };
  });
  // Parents must be in the file, without loops; subcategories get their top level's kind.
  const tree = categoryTree(categories);
  for (const c of categories) {
    if (c.parent_id && (!ids.has(c.parent_id) || tree.parentOf(c.id)?.id !== c.parent_id)) {
      throw new HttpError(400, `Invalid parent "${c.parent_id}" of category "${c.id}"`);
    }
    c.kind = tree.atLevel(c.id, 1).kind;
  }
  const accountsRaw = f.accounts ?? [];
  if (!Array.isArray(accountsRaw)) throw new HttpError(400, "finance.accounts must be an array");
  if (accountsRaw.length > MAX_ACCOUNTS) throw new HttpError(400, "Too many accounts");
  const accountIds = new Set<string>();
  const accounts = accountsRaw.map((raw: unknown, i: number): AccountRow => {
    const a = objectOf(raw, "Each account");
    if (typeof a.id !== "string" || !CATEGORY_ID_RE.test(a.id) || accountIds.has(a.id)) {
      throw new HttpError(400, `Invalid account id "${a.id}"`);
    }
    accountIds.add(a.id);
    return {
      family_id: familyId,
      id: a.id,
      name: cleanName(a.name),
      color: cleanColor(a.color),
      icon: text(a.icon, "icon", 16),
      opening_cents: a.openingCents === undefined ? 0 : cleanAmount(a.openingCents, "openingCents"),
      position: Number.isInteger(a.position) ? a.position as number : i,
    };
  });
  const txIds = new Set<string>();
  const hashes = new Set<string>();
  const now = new Date().toISOString();
  const transactions = f.transactions.map((raw: unknown): TransactionRow => {
    const t = objectOf(raw, "Each transaction");
    const id = typeof t.id === "string" && UUID_RE.test(t.id) ? t.id : crypto.randomUUID();
    if (txIds.has(id)) throw new HttpError(400, `Duplicate transaction id "${id}"`);
    txIds.add(id);
    const category = t.categoryId ?? null;
    if (category !== null && (typeof category !== "string" || !ids.has(category))) {
      throw new HttpError(400, `Unknown category "${category}"`);
    }
    const account = t.accountId ?? null;
    if (account !== null && (typeof account !== "string" || !accountIds.has(account))) {
      throw new HttpError(400, `Unknown account "${account}"`);
    }
    const splitOf = cleanUuid(t.splitOf, "splitOf");
    let hash = typeof t.importHash === "string" ? t.importHash.slice(0, 80) : null;
    if (hash && hashes.has(hash)) hash = null;
    if (hash) hashes.add(hash);
    return {
      family_id: familyId,
      id,
      day: cleanDate(t.date),
      amount_cents: cleanAmount(t.amountCents),
      payee: text(t.payee, "payee", 200),
      description: text(t.description, "description", 500),
      category_id: category as string | null,
      note: text(t.note, "note", 500),
      import_hash: hash,
      account_id: account as string | null,
      transfer_id: cleanUuid(t.transferId),
      split_of: splitOf,
      created_at: now,
    };
  });
  // A part's booking must be in the file, and not be a part itself.
  const byId = new Map(transactions.map((t: TransactionRow) => [t.id, t]));
  for (const t of transactions) {
    const booking = t.split_of ? byId.get(t.split_of) : undefined;
    if (t.split_of && (!booking || booking === t || booking.split_of)) {
      throw new HttpError(400, `Unknown split booking "${t.split_of}"`);
    }
  }
  return {
    currency: f.currency === undefined ? "EUR" : cleanCurrency(f.currency),
    categories,
    accounts,
    transactions,
  };
}

/** Copies the finances of one family into another (clone). */
export async function copyFinance(store: Store, from: string, to: string) {
  const [settings, categories, accounts, transactions] = await Promise.all([
    store.getFinanceSettings(from),
    store.listCategories(from),
    store.listAccounts(from),
    store.listTransactions(from),
  ]);
  if (settings) await store.saveFinanceSettings({ ...settings, family_id: to });
  await store.upsertCategories(categories.map((c) => ({ ...c, family_id: to })));
  await store.upsertAccounts(accounts.map((a) => ({ ...a, family_id: to })));
  // The copies get new ids, and their transfer groups too; parts point to the booking's copy.
  const fresh = new Map<string, string>();
  const newId = (id: string | null) => {
    if (!id) return null;
    if (!fresh.has(id)) fresh.set(id, crypto.randomUUID());
    return fresh.get(id)!;
  };
  await store.upsertTransactions(
    transactions.map((t) => ({
      ...t,
      family_id: to,
      id: newId(t.id)!,
      transfer_id: newId(t.transfer_id),
      split_of: newId(t.split_of),
    })),
  );
}

// ------------------------------------------------------------------ import hashes

function normalize(s: string) {
  return s.toLowerCase().replace(/\s+/g, " ").trim();
}

async function sha256(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].slice(0, 16).map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Import hashes for statement rows. Identical rows (two coffees for the same price on one
 * day) are told apart by how often they occurred before in the file, so importing the same or
 * an overlapping statement again skips exactly the rows that are already there. Statements of
 * an account include it, so the same booking on two accounts' statements (both legs of a
 * transfer, say) isn't taken for a duplicate.
 */
export async function importHashes(
  rows: { day: string; amount_cents: number; payee: string; description: string }[],
  accountId?: string | null,
): Promise<string[]> {
  const seen = new Map<string, number>();
  const out: string[] = [];
  for (const r of rows) {
    let key = `${r.day}|${r.amount_cents}|${normalize(r.payee)}|${normalize(r.description)}`;
    if (accountId) key += `|${accountId}`;
    const n = seen.get(key) ?? 0;
    seen.set(key, n + 1);
    out.push(await sha256(`${key}|${n}`));
  }
  return out;
}

// ------------------------------------------------------------------ transfers, splits, net counting

/** Transfer groups by transfer id, each with its legs in lead order. Only groups with at least
 *  two legs: a lone leg counts as a normal transaction. */
export type Groups = Map<string, TransactionRow[]>;

/** The parts of split bookings by booking id. */
export type Splits = Map<string, TransactionRow[]>;

/** How transactions are tied together: transfer groups and split bookings. */
export type Links = { groups: Groups; splits: Splits };

const NO_LINKS: Links = { groups: new Map(), splits: new Map() };

/** Lead order: the earliest day first, ties by id. */
function byLead(a: TransactionRow, b: TransactionRow): number {
  return a.day.localeCompare(b.day) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}

/** All legs of the transfer groups the rows touch: a range can cut a group apart, but it
 *  always counts as a whole. */
export async function loadGroups(
  store: Store,
  familyId: string,
  rows: TransactionRow[],
): Promise<Groups> {
  const groups: Groups = new Map();
  const ids = [...new Set(rows.flatMap((t) => t.transfer_id ? [t.transfer_id] : []))];
  if (!ids.length) return groups;
  for (const t of await store.listTransfers(familyId, ids)) {
    const legs = groups.get(t.transfer_id!) ?? [];
    legs.push(t);
    groups.set(t.transfer_id!, legs);
  }
  for (const [id, legs] of groups) {
    if (legs.length < 2) groups.delete(id);
    else legs.sort(byLead);
  }
  return groups;
}

/** All split bookings of the family with their parts (there are few). */
async function loadSplits(store: Store, familyId: string): Promise<Splits> {
  const splits: Splits = new Map();
  for (const t of await store.listSplitParts(familyId)) {
    splits.set(t.split_of!, [...(splits.get(t.split_of!) ?? []), t]);
  }
  return splits;
}

/** The transfer groups the rows touch and all split bookings. */
export async function loadLinks(
  store: Store,
  familyId: string,
  rows: TransactionRow[],
): Promise<Links> {
  const [groups, splits] = await Promise.all([
    loadGroups(store, familyId, rows),
    loadSplits(store, familyId),
  ]);
  return { groups, splits };
}

/** The legs of the transaction's transfer group, if it is a leg of one. */
function groupOf(t: TransactionRow, groups: Groups): TransactionRow[] | undefined {
  return t.transfer_id ? groups.get(t.transfer_id) : undefined;
}

/** What a transaction counts as: its amount, or the net (sum of the legs) of its group. */
function netOf(t: TransactionRow, groups: Groups): number {
  const legs = groupOf(t, groups);
  return legs ? legs.reduce((sum, l) => sum + l.amount_cents, 0) : t.amount_cents;
}

/** What a split booking still counts as itself: its amount minus its parts (shipping, say). */
function remainderOf(booking: TransactionRow, parts: TransactionRow[]): number {
  return parts.reduce((rest, p) => rest - p.amount_cents, booking.amount_cents);
}

/** Whether the transaction is a part or a booking of a split. */
function inSplit(t: TransactionRow, splits: Splits): boolean {
  return !!t.split_of || splits.has(t.id);
}

/**
 * Net counting, used by every income / expense total. A transaction counts with its amount; a
 * transfer group counts once, by its net: on its lead leg's day, with the first category of
 * its legs (lead first), and only if the lead leg is among the rows. So moving 500 from one
 * account to another counts nothing (net 0), and only money that leaves the family (or comes
 * in) counts. A split booking's parts count with their own amounts and categories, and the
 * booking only with what is left of it, so the totals still match the statement.
 */
export function netItems(rows: TransactionRow[], { groups, splits }: Links): NetItem[] {
  const out: NetItem[] = [];
  const item = (t: TransactionRow, amountCents: number, categoryId: string | null) => ({
    day: t.day,
    amountCents,
    categoryId,
    accountId: t.account_id,
    payee: t.payee,
    description: t.description,
  });
  for (const t of rows) {
    const parts = splits.get(t.id);
    const legs = groupOf(t, groups);
    if (parts) {
      const rest = remainderOf(t, parts);
      if (rest !== 0) out.push(item(t, rest, t.category_id));
    } else if (!legs) {
      out.push(item(t, t.amount_cents, t.category_id));
    } else if (legs[0].id === t.id) {
      const net = netOf(t, groups);
      if (net === 0) continue;
      out.push(item(t, net, legs.find((l) => l.category_id)?.category_id ?? null));
    }
  }
  return out;
}

/** What one transaction (or transfer group, or what is left of a split booking) counts as;
 *  payee, description and account are those of the transaction (a group's lead leg). */
export type NetItem = {
  day: string;
  amountCents: number;
  categoryId: string | null;
  accountId: string | null;
  payee: string;
  description: string;
};

/**
 * What makes transactions "similar": the first words of the payee (or, without one, of the
 * description), without numbers, punctuation and case, so "REWE Markt 1234 Berlin" and
 * "Rewe Markt 5678 Berlin" match.
 */
export function similarKey(t: { payee: string; description: string }): string {
  const words = (s: string) =>
    s.toLowerCase().replace(/[^\p{L}\s]+/gu, " ").split(/\s+/).filter((w) => w.length > 1);
  const payee = words(t.payee);
  return (payee.length ? payee : words(t.description)).slice(0, 3).join(" ");
}

function netTotals(items: { amountCents: number }[]) {
  let incomeCents = 0, expenseCents = 0;
  for (const it of items) {
    if (it.amountCents > 0) incomeCents += it.amountCents;
    else expenseCents -= it.amountCents;
  }
  return { incomeCents, expenseCents };
}

type SplitMatch = { booking: TransactionRow; parts: TransactionRow[] };

/** The merchant a transaction is with, roughly: the first word of its payee (or description,
 *  without the split mark), so "AMAZON PAYMENTS EUROPE" and "Amazon.de" are both "amazon". */
function merchantOf(t: TransactionRow): string {
  for (const text of [t.payee, t.description]) {
    const words = text.replace(SPLIT_RE, " ").toLowerCase().match(/[\p{L}\p{N}]{2,}/gu) ?? [];
    const word = words.find((w) => w !== "www");
    if (word) return word;
  }
  return "";
}

/** The smallest set of `parts` whose amounts add up to `cents` exactly, if any. */
function exactParts(parts: TransactionRow[], cents: number): TransactionRow[] | undefined {
  if (!parts.length || parts.length > MAX_SPLIT_SEARCH) return;
  let best: TransactionRow[] | undefined;
  for (let mask = 1; mask < 1 << parts.length; mask++) {
    const pick = parts.filter((_, i) => mask & (1 << i));
    if (best && pick.length >= best.length) continue;
    if (pick.reduce((sum, t) => sum + t.amount_cents, 0) === cents) best = pick;
  }
  return best;
}

/** The order number an order line names ("Bestellnr. 306-1234567-1234567"), lower case and
 *  without dashes. */
function orderOf(t: TransactionRow): string {
  return t.description.match(ORDER_RE)?.[1].replaceAll("-", "").toLowerCase() ?? "";
}

/** The words of a transaction's payee and description like orderOf: lower case, and words
 *  joined by dashes (order numbers) as one word without them. */
function wordsOf(t: TransactionRow): string[] {
  const words = `${t.payee} ${t.description}`.match(/[\p{L}\p{N}]+(?:-[\p{L}\p{N}]+)*/gu);
  return (words ?? []).map((w) => w.replaceAll("-", "").toLowerCase());
}

/**
 * Splits `left` among `bookings` (of one day and account): with several bookings, each first
 * takes the parts that add up to it exactly. The parts left over go to the one booking without
 * an exact match, if there is just one: all of them if they add up to at most its amount in the
 * same direction (the rest being shipping, say), else the ones that add up to it exactly.
 * `all` gives every part left over to that booking (or else the largest one) all the same.
 */
function assignParts(
  bookings: TransactionRow[],
  left: TransactionRow[],
  all = false,
): SplitMatch[] {
  bookings = [...bookings].sort((a, b) =>
    Math.abs(b.amount_cents) - Math.abs(a.amount_cents) || byLead(a, b)
  );
  left = [...left].sort(byLead);
  const out: SplitMatch[] = [];
  const unmatched: TransactionRow[] = [];
  for (const booking of bookings) {
    const parts = bookings.length > 1 ? exactParts(left, booking.amount_cents) : undefined;
    if (!parts) unmatched.push(booking);
    else {
      out.push({ booking, parts });
      left = left.filter((t) => !parts.includes(t));
    }
  }
  if (!left.length) return out;
  if (all) {
    const booking = unmatched.length === 1 ? unmatched[0] : bookings[0];
    return [...out, { booking, parts: left }];
  }
  if (unmatched.length !== 1) return out;
  const [booking] = unmatched;
  const sum = left.reduce((s, t) => s + t.amount_cents, 0);
  const fits = Math.sign(sum) === Math.sign(booking.amount_cents) &&
    Math.abs(sum) <= Math.abs(booking.amount_cents);
  const parts = fits ? left : exactParts(left, booking.amount_cents);
  if (parts) out.push({ booking, parts });
  return out;
}

/**
 * Split bookings by order number: order lines without a payee that name an order ("Bestellnr.
 * 306-…") are the parts of a transaction with a payee on the same account that names the same
 * order (the bank's booking, "AMAZON PAYMENTS EUROPE S.C.A." with the order number): of the
 * same day, or else of the closest day at most TRANSFER_DAYS away. All of them, even when they
 * add up to more than the booking (an order line listed twice, a discount), as the bank books
 * only the booking; the booking's remainder evens it out, so totals match the statement. A
 * booking in `booked` (one with parts already) takes more parts.
 */
function matchOrders(rows: TransactionRow[], booked: Set<string>): SplitMatch[] {
  const lines = new Map<string, TransactionRow[]>();
  for (const t of rows) {
    const order = t.payee.trim() || booked.has(t.id) ? "" : orderOf(t);
    if (!order) continue;
    const key = `${t.account_id ?? ""}|${order}`;
    lines.set(key, [...(lines.get(key) ?? []), t]);
  }
  if (!lines.size) return [];
  const bookings = new Map<string, TransactionRow[]>();
  for (const t of rows) {
    if (!t.payee.trim()) continue;
    for (const word of new Set(wordsOf(t))) {
      const key = `${t.account_id ?? ""}|${word}`;
      if (lines.has(key)) bookings.set(key, [...(bookings.get(key) ?? []), t]);
    }
  }
  const parts = new Map<TransactionRow, TransactionRow[]>();
  for (const [key, all] of lines) {
    const candidates = bookings.get(key) ?? [];
    for (const day of new Set(all.map((t) => t.day))) {
      const gap = (t: TransactionRow) => Math.abs(diffDays(t.day, day));
      const near = candidates.filter((t) => gap(t) <= TRANSFER_DAYS);
      if (!near.length) continue;
      const closest = Math.min(...near.map(gap));
      const onDay = near.filter((t) => gap(t) === closest);
      const firstDay = onDay.map((t) => t.day).sort()[0];
      const free = all.filter((t) => t.day === day);
      for (const m of assignParts(onDay.filter((t) => t.day === firstDay), free, true)) {
        parts.set(m.booking, [...(parts.get(m.booking) ?? []), ...m.parts]);
      }
    }
  }
  return [...parts].map(([booking, parts]) => ({ booking, parts }));
}

/**
 * Split bookings among transactions that aren't parts yet. First by order number (see
 * matchOrders, where a booking in `booked` may take more parts); then, among the rest that
 * aren't bookings either, a transaction marked "Splitbuchung" (in payee or description) takes
 * the other transactions of the same day, account and merchant as its parts (see assignParts).
 */
export function matchSplits(
  rows: TransactionRow[],
  booked = new Set<string>(),
): SplitMatch[] {
  const out = matchOrders(rows, booked);
  const taken = new Set(out.flatMap((m) => [m.booking, ...m.parts]));
  const byKey = new Map<string, TransactionRow[]>();
  for (const t of rows) {
    if (taken.has(t) || booked.has(t.id)) continue;
    const key = `${t.day}|${t.account_id ?? ""}|${merchantOf(t)}`;
    byKey.set(key, [...(byKey.get(key) ?? []), t]);
  }
  for (const same of byKey.values()) {
    const bookings = same.filter((t) => SPLIT_RE.test(t.payee) || SPLIT_RE.test(t.description));
    const left = same.filter((t) => !bookings.includes(t));
    if (bookings.length && left.length) out.push(...assignParts(bookings, left));
  }
  return out.sort((a, b) => byLead(b.booking, a.booking));
}

/** Makes the matches' parts parts of their bookings; they and the bookings leave the transfers
 *  they were in. `inverse` undoes it: one "unsplit" op, then puts back the transfer ids. */
async function linkSplits(store: Store, familyId: string, matches: SplitMatch[]) {
  const pick: SplitMatch[] = [];
  let count = 0;
  for (const m of matches) {
    if (count + m.parts.length + 1 > MAX_OPS) break;
    pick.push(m);
    count += m.parts.length + 1;
  }
  const before = pick.flatMap((m) => [m.booking, ...m.parts]);
  await store.upsertTransactions(
    pick.flatMap((m) => [
      { ...m.booking, transfer_id: null },
      ...m.parts.map((p) => ({ ...p, transfer_id: null, split_of: m.booking.id })),
    ]),
  );
  const lone = await clearLoneLegs(store, familyId, before);
  const parts = pick.flatMap((m) => m.parts.map((p) => p.id));
  return {
    changed: before.length,
    inverse: pick.length
      ? [
        { action: "unsplit", ids: parts },
        ...[...before, ...lone].filter((t) => t.transfer_id).map(restoreOp),
      ]
      : [],
    splits: pick.length,
  };
}

type TransferPair = { out: TransactionRow; in: TransactionRow };

/**
 * Candidate transfers among transactions that aren't in a group or a split: money out of one
 * account and the same amount into another (not both without an account), at most
 * TRANSFER_DAYS apart. Rows that look like the parts of a split booking (see matchSplits)
 * aren't transfers either, like an Amazon voucher among the order lines. Greedy one-to-one
 * matching, closest days first; newest first.
 */
export function matchTransfers(rows: TransactionRow[]): TransferPair[] {
  const split = new Set(matchSplits(rows).flatMap((m) => [m.booking, ...m.parts]));
  const ins = new Map<number, TransactionRow[]>();
  for (const t of rows) {
    if (t.amount_cents > 0 && !split.has(t)) {
      ins.set(t.amount_cents, [...(ins.get(t.amount_cents) ?? []), t]);
    }
  }
  const candidates: (TransferPair & { gap: number })[] = [];
  for (const out of rows) {
    if (out.amount_cents >= 0 || split.has(out)) continue;
    for (const into of ins.get(-out.amount_cents) ?? []) {
      if (out.account_id === into.account_id) continue;
      const gap = Math.abs(diffDays(out.day, into.day));
      if (gap <= TRANSFER_DAYS) candidates.push({ out, in: into, gap });
    }
  }
  candidates.sort((a, b) =>
    a.gap - b.gap || b.out.day.localeCompare(a.out.day) || byLead(a.out, b.out) ||
    byLead(a.in, b.in)
  );
  const used = new Set<string>();
  const pairs: TransferPair[] = [];
  for (const { out, in: into } of candidates) {
    if (used.has(out.id) || used.has(into.id)) continue;
    used.add(out.id);
    used.add(into.id);
    pairs.push({ out, in: into });
  }
  const latest = (p: TransferPair) => p.out.day > p.in.day ? p.out.day : p.in.day;
  return pairs.sort((a, b) =>
    latest(b).localeCompare(latest(a)) || b.out.day.localeCompare(a.out.day)
  );
}

/** Transactions in the range (all without one) that aren't legs of a group or in a split. */
async function unlinked(store: Store, familyId: string, from?: string, to?: string) {
  const rows = await store.listTransactions(familyId, from, to);
  const { groups, splits } = await loadLinks(store, familyId, rows);
  return rows.filter((t) => !groupOf(t, groups) && !inSplit(t, splits));
}

/** Transactions in the range (all without one) that aren't parts of a split yet: legs of
 *  transfers too, as a wrongly combined "transfer" may well be a split booking's part, and
 *  bookings (their ids in `booked`), which may take more parts. */
async function splitCandidates(store: Store, familyId: string, from?: string, to?: string) {
  const rows = await store.listTransactions(familyId, from, to);
  const splits = await loadSplits(store, familyId);
  return { rows: rows.filter((t) => !t.split_of), booked: new Set(splits.keys()) };
}

/** The pairs that look like transfers in the range (all without one), newest first. */
export async function transferPairs(store: Store, familyId: string, from?: string, to?: string) {
  return matchTransfers(await unlinked(store, familyId, from, to));
}

/** Links each pair (of ungrouped transactions) as its own group; `inverse` undoes it: one
 *  "unlink" op (so it stays within MAX_OPS), then puts back the transfer ids of lone legs. */
export async function linkTransferPairs(store: Store, pairs: TransferPair[]) {
  const pick = pairs.slice(0, MAX_OPS);
  const before = pick.flatMap((p) => [p.out, p.in]);
  const linked = pick.flatMap((p) => {
    const transferId = crypto.randomUUID();
    return [{ ...p.out, transfer_id: transferId }, { ...p.in, transfer_id: transferId }];
  });
  await store.upsertTransactions(linked);
  return {
    ok: true,
    changed: linked.length,
    added: [] as string[],
    inverse: before.length
      ? [
        { action: "unlink", ids: before.map((t) => t.id) },
        ...before.filter((t) => t.transfer_id).map(restoreOp),
      ]
      : [],
    linked: pick.length,
  };
}

/**
 * Auto-combine in the range (all without one): first the split bookings, then the transfers
 * among what is left. `only` limits it to splits and transfers with one of these transactions
 * (fresh imports). `inverse` undoes both.
 */
export async function autoCombine(
  store: Store,
  familyId: string,
  from?: string,
  to?: string,
  only?: Set<string>,
) {
  const touches = (ts: TransactionRow[]) => !only || ts.some((t) => only.has(t.id));
  const { rows, booked } = await splitCandidates(store, familyId, from, to);
  const matches = matchSplits(rows, booked)
    .filter((m) => touches([m.booking, ...m.parts]));
  const splits = await linkSplits(store, familyId, matches);
  const pairs = matchTransfers(await unlinked(store, familyId, from, to))
    .filter((p) => touches([p.out, p.in]));
  const transfers = await linkTransferPairs(store, pairs);
  return {
    ok: true,
    changed: splits.changed + transfers.changed,
    added: [] as string[],
    // The transfers are undone first, as they were linked last.
    inverse: [...transfers.inverse, ...splits.inverse],
    linked: transfers.linked,
    splits: splits.splits,
  };
}

// ------------------------------------------------------------------ routes

/** Routes /families/{id}/finance/...; null for anything else. */
export function handleFinance(ctx: Ctx): Promise<Response> | null {
  if (ctx.rest[0] !== "finance") return null;
  const [, sub, id] = ctx.rest;
  const { method } = ctx;
  if (sub === undefined && method === "GET") return overview(ctx);
  if (sub === undefined && method === "DELETE") return clearRoute(ctx);
  if (sub === "settings" && id === undefined && method === "PATCH") return updateSettings(ctx);
  if (sub === "categories") return categoriesRoute(ctx, id);
  if (sub === "accounts") return accountsRoute(ctx, id);
  if (sub === "transactions" && id === undefined) {
    if (method === "GET") return listRoute(ctx);
    if (method === "POST") return changeTransactions(ctx);
  }
  if (sub === "transfers" && id === "suggestions" && method === "GET") {
    return suggestionsRoute(ctx);
  }
  if (sub === "transfers" && id === "auto" && method === "POST") return autoTransfersRoute(ctx);
  if (sub === "import" && id === undefined && method === "POST") return importRoute(ctx);
  if (sub === "summary" && id === undefined && method === "GET") return summaryRoute(ctx);
  return Promise.reject(new HttpError(404, "Not found"));
}

async function overviewData(store: Store, familyId: string) {
  const [settings, categories, accounts] = await Promise.all([
    store.getFinanceSettings(familyId),
    store.listCategories(familyId),
    listAccounts(store, familyId),
  ]);
  const s = settingsOf(familyId, settings);
  return {
    currency: s.currency,
    csvMappings: s.csv_mappings,
    benchmark: benchmarkOf(s, categories),
    // Phase 7: the category whose spending the shopping lists show (null: the default).
    groceriesCategoryId:
      s.groceries_category_id && categories.some((c) => c.id === s.groceries_category_id)
        ? s.groceries_category_id
        : null,
    categories: categories.map(publicCategory),
    accounts,
  };
}

/** GET /finance: currency, saved CSV mappings, the statistic average, the categories and the
 *  accounts. */
async function overview({ finance: store, load }: Ctx): Promise<Response> {
  const { family } = await load("view");
  return json(await overviewData(store, family.id));
}

/** DELETE /finance: deletes all transactions, accounts, categories and settings. */
async function clearRoute({ finance: store, load }: Ctx): Promise<Response> {
  const { family } = await load("edit");
  await store.clearFinance(family.id);
  return json(await overviewData(store, family.id));
}

/** PATCH /finance/settings {"currency": "EUR", "csvMappings": [...], "benchmark": {...},
 *  "groceriesCategoryId": "groceries"} (benchmark: see cleanBenchmark; null clears it;
 *  groceriesCategoryId: a category by id or name, null for the default) */
async function updateSettings({ finance: store, req, load }: Ctx): Promise<Response> {
  const { family } = await load("edit");
  const body = await readBody(req);
  const row = settingsOf(family.id, await store.getFinanceSettings(family.id));
  if (body.currency !== undefined) row.currency = cleanCurrency(body.currency);
  if (body.csvMappings !== undefined) {
    if (!Array.isArray(body.csvMappings) || body.csvMappings.length > MAX_MAPPINGS) {
      throw new HttpError(400, `csvMappings must be an array of at most ${MAX_MAPPINGS}`);
    }
    if (JSON.stringify(body.csvMappings).length > 20_000) {
      throw new HttpError(400, "csvMappings is too large");
    }
    row.csv_mappings = body.csvMappings;
  }
  if (body.benchmark !== undefined) {
    row.benchmark = cleanBenchmark(body.benchmark, await store.listCategories(family.id));
  }
  if (body.groceriesCategoryId !== undefined) {
    row.groceries_category_id = body.groceriesCategoryId === null || body.groceriesCategoryId === ""
      ? null
      : findCategory(await store.listCategories(family.id), body.groceriesCategoryId).id;
  }
  await store.saveFinanceSettings(row);
  return json(await overviewData(store, family.id));
}

async function categoriesRoute(ctx: Ctx, id: string | undefined): Promise<Response> {
  const { finance: store, req, method, load } = ctx;
  const { family } = await load("edit");
  const categories = await store.listCategories(family.id);
  const body = await readBody(req);

  if (id === "defaults" && method === "POST") {
    // Adds the default categories the family doesn't have yet (by id).
    const lang: Lang = body.lang === "de" ? "de" : "en";
    const taken = new Set(categories.map((c) => c.id));
    let position = categories.reduce((m, c) => Math.max(m, c.position + 1), 0);
    const add = defaultCategories(family.id, lang).filter((c) => !taken.has(c.id))
      .slice(0, Math.max(0, MAX_CATEGORIES - categories.length))
      .map((c) => ({ ...c, position: position++ }));
    await store.upsertCategories(add);
    return json([...categories, ...add].map(publicCategory));
  }

  if (id === undefined && method === "POST") {
    const row = newCategory(family.id, categories, body);
    await store.upsertCategories([row]);
    return json(publicCategory(row), 201);
  }

  if (id !== undefined) {
    const current = findCategory(categories, id);
    if (method === "PATCH") {
      const changed = changedCategories(categories, current, body);
      await store.upsertCategories(changed);
      return json(publicCategory(changed[0]));
    }
    if (method === "DELETE") {
      await store.deleteCategory(family.id, current.id);
      return json({ deleted: current.id });
    }
  }
  throw new HttpError(405, "Method not allowed");
}

async function accountsRoute(ctx: Ctx, id: string | undefined): Promise<Response> {
  const { finance: store, req, method, load } = ctx;
  if (id === undefined && method === "GET") return accountsAtRoute(ctx);
  const { family } = await load("edit");
  const accounts = await store.listAccounts(family.id);
  const body = await readBody(req);

  if (id === undefined && method === "POST") {
    if (accounts.length >= MAX_ACCOUNTS) throw new HttpError(400, "Too many accounts");
    const name = cleanName(body.name);
    const row: AccountRow = {
      family_id: family.id,
      id: uniqueId(slug(name), new Set(accounts.map((a) => a.id)), "account"),
      name,
      color: cleanColor(body.color),
      icon: text(body.icon, "icon", 16),
      opening_cents: body.openingCents === undefined
        ? 0
        : cleanAmount(body.openingCents, "openingCents"),
      position: accounts.reduce((m, a) => Math.max(m, a.position + 1), 0),
    };
    await store.upsertAccounts([row]);
    return json(publicAccount(row, new Map()), 201);
  }

  if (id !== undefined) {
    const current = accounts.find((a) => a.id === resolveAccount(accounts, id));
    if (!current) throw new HttpError(404, `Unknown account "${id}"`);
    if (method === "PATCH") {
      const next = { ...current };
      if (body.name !== undefined) next.name = cleanName(body.name);
      if (body.color !== undefined) next.color = cleanColor(body.color);
      if (body.icon !== undefined) next.icon = text(body.icon, "icon", 16);
      if (body.openingCents !== undefined) {
        next.opening_cents = cleanAmount(body.openingCents, "openingCents");
      }
      if (body.position !== undefined) {
        if (!Number.isInteger(body.position)) {
          throw new HttpError(400, "position must be an integer");
        }
        next.position = body.position as number;
      }
      await store.upsertAccounts([next]);
      return json(publicAccount(next, await store.accountTotals(family.id)));
    }
    if (method === "DELETE") {
      // Its transactions go too; a transfer's leg on another account is left alone.
      const gone = await store.deleteAccount(family.id, current.id);
      await clearLoneLegs(store, family.id, gone);
      return json({ deleted: current.id, transactions: gone.length });
    }
  }
  throw new HttpError(405, "Method not allowed");
}

/** GET /finance/accounts?at=YYYY-MM-DD: the accounts with their balances at the end of that
 *  day (opening balance plus the transactions up to it); without `at`, now. */
async function accountsAtRoute({ finance: store, url, load }: Ctx): Promise<Response> {
  const { family } = await load("view");
  const at = url.searchParams.get("at") ?? undefined;
  if (at !== undefined && !isValidDate(at)) throw new HttpError(400, "at must be YYYY-MM-DD");
  return json({ at: at ?? null, accounts: await listAccounts(store, family.id, at) });
}

/** A validated range; without from or to it is open on that side. */
function cleanRange(from: unknown, to: unknown) {
  for (const d of [from, to]) {
    if (d !== undefined && !isValidDate(d)) throw new HttpError(400, "from/to must be YYYY-MM-DD");
  }
  return { from: from as string | undefined, to: to as string | undefined };
}

/** ?from&to */
function rangeOf(query: URLSearchParams) {
  return cleanRange(query.get("from") ?? undefined, query.get("to") ?? undefined);
}

/**
 * Transactions matching ?from&to&account&category&q&kind (newest first), their links
 * (transfer groups and splits), and the income and expense totals of the rows (net counting).
 */
export async function findTransactions(store: Store, familyId: string, query: URLSearchParams) {
  const { from, to } = rangeOf(query);
  let rows = await store.listTransactions(familyId, from, to);
  const account = query.get("account");
  if (account === "none") rows = rows.filter((t) => !t.account_id);
  else if (account) {
    const id = resolveAccount(await store.listAccounts(familyId), account);
    rows = rows.filter((t) => t.account_id === id);
  }
  const category = query.get("category");
  if (category === "none") rows = rows.filter((t) => !t.category_id);
  else if (category) {
    // A category with its subcategories.
    const categories = await store.listCategories(familyId);
    const ids = categoryTree(categories).subtree(resolveCategory(categories, category)!);
    rows = rows.filter((t) => t.category_id && ids.has(t.category_id));
  }
  const q = query.get("q")?.trim().toLowerCase();
  if (q) {
    rows = rows.filter((t) =>
      t.payee.toLowerCase().includes(q) || t.description.toLowerCase().includes(q) ||
      t.note.toLowerCase().includes(q)
    );
  }
  const links = await loadLinks(store, familyId, rows);
  const { groups } = links;
  // Legs of a group go by the group's net: a net-0 transfer is neither income nor expense.
  const kind = query.get("kind");
  if (kind === "transfer") rows = rows.filter((t) => !!groupOf(t, groups));
  else if (kind === "income") rows = rows.filter((t) => netOf(t, groups) > 0);
  else if (kind === "expense") rows = rows.filter((t) => netOf(t, groups) < 0);
  return { rows, links, ...netTotals(netItems(rows, links)) };
}

/** GET /finance/transactions?from&to&account=<id|none>&category=<id|none>&q
 *  &kind=income|expense|transfer&limit&offset */
async function listRoute({ finance: store, url, load }: Ctx): Promise<Response> {
  const { family } = await load("view");
  const { rows, links, incomeCents, expenseCents } = await findTransactions(
    store,
    family.id,
    url.searchParams,
  );
  const limit = Math.min(MAX_LIST, Math.max(1, Number(url.searchParams.get("limit")) || 200));
  const offset = Math.max(0, Number(url.searchParams.get("offset")) || 0);
  return json({
    transactions: rows.slice(offset, offset + limit).map((t) => publicTransaction(t, links)),
    total: rows.length,
    incomeCents,
    expenseCents,
  });
}

type TxOp =
  | { action: "add"; row: TransactionRow }
  | { action: "update"; id: string; patch: Partial<TransactionRow> }
  | { action: "delete" | "unlink" | "unsplit"; ids: string[] }
  | { action: "link"; ids: string[] }
  | { action: "split"; id: string; ids: string[] };

/** The op's "ids" (or "id"), at least `min` distinct uuids. */
function idsOf(o: Record<string, unknown>, action: string, min: number): string[] {
  const ids = o.ids ?? (o.id !== undefined ? [o.id] : []);
  if (!Array.isArray(ids) || ids.some((id) => typeof id !== "string" || !UUID_RE.test(id))) {
    throw new HttpError(400, `"${action}" needs "id" or "ids" (uuids)`);
  }
  const unique = [...new Set(ids as string[])];
  if (unique.length < min) {
    throw new HttpError(
      400,
      min > 1 ? `"${action}" needs at least ${min} "ids"` : `"${action}" needs "id" or "ids"`,
    );
  }
  return unique;
}

function parseTxOp(
  raw: unknown,
  categories: CategoryRow[],
  accounts: AccountRow[],
  familyId: string,
  now: string,
): TxOp {
  const o = objectOf(raw, "Each op");
  const action = o.action ?? "add";
  if (action === "add") {
    if (o.id !== undefined && (typeof o.id !== "string" || !UUID_RE.test(o.id))) {
      throw new HttpError(400, "id must be a uuid");
    }
    return {
      action,
      row: {
        family_id: familyId,
        id: (o.id as string) ?? crypto.randomUUID(),
        day: cleanDate(o.date),
        amount_cents: cleanAmount(o.amountCents),
        payee: text(o.payee, "payee", 200),
        description: text(o.description, "description", 500),
        category_id: resolveCategory(categories, o.categoryId),
        note: text(o.note, "note", 500),
        import_hash: null,
        account_id: resolveAccount(accounts, o.accountId),
        transfer_id: cleanUuid(o.transferId),
        split_of: cleanUuid(o.splitOf, "splitOf"),
        created_at: now,
      },
    };
  }
  if (action === "update") {
    if (typeof o.id !== "string" || !UUID_RE.test(o.id)) {
      throw new HttpError(400, "id must be a uuid");
    }
    const patch: Partial<TransactionRow> = {};
    if (o.date !== undefined) patch.day = cleanDate(o.date);
    if (o.amountCents !== undefined) patch.amount_cents = cleanAmount(o.amountCents);
    if (o.payee !== undefined) patch.payee = text(o.payee, "payee", 200);
    if (o.description !== undefined) patch.description = text(o.description, "description", 500);
    if (o.categoryId !== undefined) patch.category_id = resolveCategory(categories, o.categoryId);
    if (o.accountId !== undefined) patch.account_id = resolveAccount(accounts, o.accountId);
    if (o.transferId !== undefined) patch.transfer_id = cleanUuid(o.transferId);
    if (o.note !== undefined) patch.note = text(o.note, "note", 500);
    return { action, id: o.id, patch };
  }
  if (action === "delete" || action === "unlink" || action === "unsplit") {
    return { action, ids: idsOf(o, action, 1) };
  }
  if (action === "link") return { action, ids: idsOf(o, action, 2) };
  if (action === "split") {
    if (typeof o.id !== "string" || !UUID_RE.test(o.id)) {
      throw new HttpError(400, '"split" needs "id": the booking\'s uuid');
    }
    const ids = idsOf({ ids: o.ids }, action, 1);
    if (ids.includes(o.id)) throw new HttpError(400, "A booking can't be a part of itself");
    return { action, id: o.id, ids };
  }
  throw new HttpError(400, "action must be add, update, delete, link, unlink, split or unsplit");
}

/** The op that puts a transaction back the way it was (for undo). */
function restoreOp(t: TransactionRow) {
  return {
    action: "add",
    id: t.id,
    date: t.day,
    amountCents: t.amount_cents,
    payee: t.payee,
    description: t.description,
    categoryId: t.category_id,
    accountId: t.account_id,
    transferId: t.transfer_id,
    splitOf: t.split_of,
    note: t.note,
  };
}

/** The transactions with these ids; 404 if one is missing. */
async function existing(store: Store, familyId: string, ids: string[]) {
  const rows = await store.getTransactions(familyId, ids);
  const found = new Set(rows.map((t) => t.id));
  const missing = ids.find((id) => !found.has(id));
  if (missing) throw new HttpError(404, `Unknown transaction "${missing}"`);
  return rows;
}

/** After `rows` left their groups: clears the transfer id of a leg left alone in one, and
 *  returns those legs as they were. */
async function clearLoneLegs(store: Store, familyId: string, rows: TransactionRow[]) {
  const ids = [...new Set(rows.flatMap((t) => t.transfer_id ? [t.transfer_id] : []))];
  if (!ids.length) return [];
  const legs = new Map<string, TransactionRow[]>();
  for (const t of await store.listTransfers(familyId, ids)) {
    legs.set(t.transfer_id!, [...(legs.get(t.transfer_id!) ?? []), t]);
  }
  const lone = [...legs.values()].filter((l) => l.length === 1).map(([t]) => t);
  await store.upsertTransactions(lone.map((t) => ({ ...t, transfer_id: null })));
  return lone;
}

/** Bookings before parts, so restoring them never points a part at a missing booking. */
function bookingsFirst(rows: TransactionRow[]) {
  return [...rows].sort((a, b) => Number(!!a.split_of) - Number(!!b.split_of));
}

/** 400 if the row can't be stored like this: a part's booking must exist and not be a part
 *  or a transfer leg itself, and neither parts nor bookings can be transfer legs. */
async function checkSplit(store: Store, familyId: string, row: TransactionRow) {
  if (!row.split_of && !row.transfer_id) return;
  const splits = await loadSplits(store, familyId);
  const isBooking = (splits.get(row.id) ?? []).some((p) => p.id !== row.id);
  if (row.transfer_id && (row.split_of || isBooking)) {
    throw new HttpError(400, "A split booking or its part can't be a leg of a transfer");
  }
  if (!row.split_of) return;
  if (isBooking) throw new HttpError(400, "A split booking can't be a part of another one");
  const [booking] = await store.getTransactions(familyId, [row.split_of]);
  if (!booking || booking.id === row.id) {
    throw new HttpError(404, `Unknown split booking "${row.split_of}"`);
  }
  if (booking.split_of) throw new HttpError(400, "A part can't have parts of its own");
  if (booking.transfer_id) {
    throw new HttpError(400, "A leg of a transfer can't be a split booking");
  }
}

/**
 * Applies transaction ops in order and returns `inverse`: the ops that undo them (send them
 * to the same endpoint). Shared with the AI assistant's tools.
 */
export async function applyTransactionOps(store: Store, familyId: string, rawOps: unknown[]) {
  if (rawOps.length > MAX_OPS) throw new HttpError(400, "Too many ops in one request");
  const [categories, accounts] = await Promise.all([
    store.listCategories(familyId),
    store.listAccounts(familyId),
  ]);
  // One time for all ops: what one request adds keeps its order within a day.
  const now = new Date().toISOString();
  const ops = rawOps.map((o) => parseTxOp(o, categories, accounts, familyId, now));
  const inverse: Record<string, unknown>[] = [];
  const added: string[] = [];
  let changed = 0;
  for (const op of ops) {
    if (op.action === "add") {
      const [before] = await store.getTransactions(familyId, [op.row.id]);
      await checkSplit(store, familyId, op.row);
      await store.upsertTransactions([{ ...op.row, import_hash: before?.import_hash ?? null }]);
      inverse.unshift(before ? restoreOp(before) : { action: "delete", ids: [op.row.id] });
      added.push(op.row.id);
      changed++;
    } else if (op.action === "update") {
      const [before] = await store.getTransactions(familyId, [op.id]);
      if (!before) throw new HttpError(404, `Unknown transaction "${op.id}"`);
      const next = { ...before, ...op.patch };
      if (op.patch.transfer_id) await checkSplit(store, familyId, next);
      await store.upsertTransactions([next]);
      inverse.unshift(restoreOp(before));
      changed++;
    } else if (op.action === "delete") {
      // Parts of a deleted booking stay as normal transactions; undo makes them parts again.
      const before = await store.getTransactions(familyId, op.ids);
      const gone = new Set(op.ids);
      const orphans = [...(await loadSplits(store, familyId)).entries()]
        .flatMap(([id, parts]) => gone.has(id) ? parts.filter((p) => !gone.has(p.id)) : []);
      await store.deleteTransactions(familyId, op.ids);
      const lone = await clearLoneLegs(store, familyId, before);
      inverse.unshift(...[...bookingsFirst(before), ...lone, ...orphans].map(restoreOp));
      changed += before.length;
    } else if (op.action === "link") {
      // The transactions leave the groups they were in and form a new one.
      const before = await existing(store, familyId, op.ids);
      const splits = await loadSplits(store, familyId);
      if (before.some((t) => inSplit(t, splits))) {
        throw new HttpError(400, "A split booking or its part can't be a leg of a transfer");
      }
      const transferId = crypto.randomUUID();
      await store.upsertTransactions(before.map((t) => ({ ...t, transfer_id: transferId })));
      const lone = await clearLoneLegs(store, familyId, before);
      inverse.unshift(...[...before, ...lone].map(restoreOp));
      changed += before.length;
    } else if (op.action === "unlink") {
      // Unlinking a leg dissolves its whole group.
      const rows = await existing(store, familyId, op.ids);
      const ids = [...new Set(rows.flatMap((t) => t.transfer_id ? [t.transfer_id] : []))];
      const legs = ids.length ? await store.listTransfers(familyId, ids) : [];
      await store.upsertTransactions(legs.map((t) => ({ ...t, transfer_id: null })));
      inverse.unshift(...legs.map(restoreOp));
      changed += legs.length;
    } else if (op.action === "split") {
      // The parts (and the booking) leave the transfers they were in; parts of another
      // booking move to this one.
      const [booking] = await existing(store, familyId, [op.id]);
      const parts = await existing(store, familyId, op.ids);
      const splits = await loadSplits(store, familyId);
      if (booking.split_of) throw new HttpError(400, "A part can't have parts of its own");
      if (parts.some((t) => splits.has(t.id))) {
        throw new HttpError(400, "A split booking can't be a part of another one");
      }
      await store.upsertTransactions([
        { ...booking, transfer_id: null },
        ...parts.map((t) => ({ ...t, transfer_id: null, split_of: booking.id })),
      ]);
      const lone = await clearLoneLegs(store, familyId, [booking, ...parts]);
      // Parts first: a booking gets its transfer back only once it has no parts.
      inverse.unshift(...[...parts, booking, ...lone].map(restoreOp));
      changed += parts.length + 1;
    } else {
      // Unsplitting a booking makes all of its parts normal transactions again.
      const rows = await existing(store, familyId, op.ids);
      const splits = await loadSplits(store, familyId);
      const parts = new Map<string, TransactionRow>();
      for (const t of rows) {
        if (t.split_of) parts.set(t.id, t);
        for (const p of splits.get(t.id) ?? []) parts.set(p.id, p);
      }
      await store.upsertTransactions([...parts.values()].map((t) => ({ ...t, split_of: null })));
      inverse.unshift(...[...parts.values()].map(restoreOp));
      changed += parts.size;
    }
  }
  return { ok: true, changed, added, inverse };
}

/** POST /finance/transactions {"ops": [...]} or a single op. */
async function changeTransactions({ finance: store, req, load }: Ctx): Promise<Response> {
  const { family } = await load("edit");
  const body = await readBody(req);
  const ops = Array.isArray(body.ops) ? body.ops : [body];
  return json(await applyTransactionOps(store, family.id, ops));
}

/** GET /finance/transfers/suggestions?from&to: transaction pairs that look like transfers
 *  between two accounts, to be linked with "link" ops. */
async function suggestionsRoute({ finance: store, url, load }: Ctx): Promise<Response> {
  const { family } = await load("view");
  const { from, to } = rangeOf(url.searchParams);
  const pairs = await transferPairs(store, family.id, from, to);
  return json({
    pairs: pairs.slice(0, MAX_SUGGESTIONS).map((p) => ({
      out: publicTransaction(p.out, NO_LINKS),
      in: publicTransaction(p.in, NO_LINKS),
    })),
  });
}

/** POST /finance/transfers/auto {"from", "to"} (both optional: all of the history): combines
 *  the split bookings ("Splitbuchung", see matchSplits) and then every suggested transfer pair
 *  in the range, like "split" and "link" ops; `splits` and `linked` count them, `inverse`
 *  undoes it. */
async function autoTransfersRoute({ finance: store, req, load }: Ctx): Promise<Response> {
  const { family } = await load("edit");
  const body = await readBody(req);
  const { from, to } = cleanRange(body.from ?? undefined, body.to ?? undefined);
  return json(await autoCombine(store, family.id, from, to));
}

/** POST /finance/import {"rows": [{date, amountCents, payee, description, categoryId}],
 *  "accountId", "autoTransfers": true, "dryRun": true}: adds the rows that aren't imported
 *  yet, all to the account if given. With autoTransfers, fresh rows that make up a split
 *  booking get combined (see matchSplits), and fresh rows that look like one leg of a transfer
 *  (see matchTransfers) get linked to the other leg; `splits` and `transfers` count them. */
async function importRoute({ finance: store, req, load }: Ctx): Promise<Response> {
  const { family } = await load("edit");
  const body = await readBody(req);
  if (!Array.isArray(body.rows)) throw new HttpError(400, "rows must be an array");
  if (body.rows.length > MAX_IMPORT_ROWS) throw new HttpError(400, "Too many rows");
  const [categories, accounts] = await Promise.all([
    store.listCategories(family.id),
    store.listAccounts(family.id),
  ]);
  const accountId = resolveAccount(accounts, body.accountId);
  const now = new Date().toISOString();
  const rows = body.rows.map((raw: unknown): TransactionRow => {
    const o = objectOf(raw, "Each row");
    return {
      family_id: family.id,
      id: crypto.randomUUID(),
      day: cleanDate(o.date),
      amount_cents: cleanAmount(o.amountCents),
      payee: text(o.payee, "payee", 200),
      description: text(o.description, "description", 500),
      category_id: resolveCategory(categories, o.categoryId),
      note: "",
      import_hash: null,
      account_id: accountId,
      transfer_id: null,
      split_of: null,
      created_at: now,
    };
  });
  const hashes = await importHashes(rows, accountId);
  const existingHashes = await store.existingImportHashes(family.id, hashes);
  const duplicates: number[] = [];
  const fresh: TransactionRow[] = [];
  rows.forEach((row: TransactionRow, i: number) => {
    if (existingHashes.has(hashes[i])) duplicates.push(i);
    else fresh.push({ ...row, import_hash: hashes[i] });
  });
  const dryRun = body.dryRun === true;
  if (!dryRun) await store.upsertTransactions(fresh);
  let transfers = 0, splits = 0;
  if (body.autoTransfers === true && fresh.length) {
    // Splits and transfers among the transactions around the fresh rows, with a fresh one. A
    // dry run adds the fresh rows in memory.
    const days = fresh.map((t) => t.day).sort();
    const from = addDays(days[0], -TRANSFER_DAYS);
    const to = addDays(days.at(-1)!, TRANSFER_DAYS);
    const ids = new Set(fresh.map((t) => t.id));
    if (dryRun) {
      const touches = (ts: TransactionRow[]) => ts.some((t) => ids.has(t.id));
      const [candidates, around] = await Promise.all([
        splitCandidates(store, family.id, from, to),
        unlinked(store, family.id, from, to),
      ]);
      splits = matchSplits([...fresh, ...candidates.rows], candidates.booked)
        .filter((m) => touches([m.booking, ...m.parts])).length;
      transfers = Math.min(
        matchTransfers([...fresh, ...around]).filter((p) => touches([p.out, p.in])).length,
        MAX_OPS,
      );
    } else {
      ({ linked: transfers, splits } = await autoCombine(store, family.id, from, to, ids));
    }
  }
  return json({
    added: dryRun ? 0 : fresh.length,
    duplicates,
    ids: dryRun ? [] : fresh.map((t) => t.id),
    transfers,
    splits,
  });
}

/** Income and expenses per month and per category in the range (net counting: a transfer
 *  group is one item, in its lead leg's month; a split booking counts by its parts). */
export async function financeSummary(store: Store, familyId: string, from?: string, to?: string) {
  const [settings, rows] = await Promise.all([
    store.getFinanceSettings(familyId),
    store.listTransactions(familyId, from, to),
  ]);
  const items = netItems(rows, await loadLinks(store, familyId, rows));
  const months = new Map<string, { month: string; incomeCents: number; expenseCents: number }>();
  const cats = new Map<
    string | null,
    { categoryId: string | null; incomeCents: number; expenseCents: number; count: number }
  >();
  let income = 0, expense = 0;
  for (const t of items) {
    const month = t.day.slice(0, 7);
    const m = months.get(month) ?? { month, incomeCents: 0, expenseCents: 0 };
    const c = cats.get(t.categoryId) ??
      { categoryId: t.categoryId, incomeCents: 0, expenseCents: 0, count: 0 };
    if (t.amountCents > 0) {
      m.incomeCents += t.amountCents;
      c.incomeCents += t.amountCents;
      income += t.amountCents;
    } else {
      m.expenseCents -= t.amountCents;
      c.expenseCents -= t.amountCents;
      expense -= t.amountCents;
    }
    c.count++;
    months.set(month, m);
    cats.set(t.categoryId, c);
  }
  return {
    currency: settingsOf(familyId, settings).currency,
    incomeCents: income,
    expenseCents: expense,
    count: items.length,
    months: [...months.values()].sort((a, b) => a.month.localeCompare(b.month)),
    categories: [...cats.values()].sort((a, b) => b.expenseCents - a.expenseCents),
  };
}

/** GET /finance/summary?from&to */
async function summaryRoute({ finance: store, url, load }: Ctx): Promise<Response> {
  const { family } = await load("view");
  const { from, to } = rangeOf(url.searchParams);
  return json(await financeSummary(store, family.id, from, to));
}
