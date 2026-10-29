// The open family's finances on the client (family-planner's features/finance/store.ts):
// accounts, categories and settings, the transactions of the chosen period (filtered), and the
// summary. Changes go straight to the API; each one can be undone from its toast with the
// inverse ops the API returns. Account balances come with the overview, so it reloads after
// every change that can move money; their balances at the end of the period (or today, while
// it runs) load with what is shown. (Sorting into categories with the AI comes with the
// assistant.)

import type { CsvMapping } from "@/lib/finance/csv";
import type { TVars } from "@/lib/i18n/translate";
import {
  type Account,
  type Benchmark,
  type Category,
  type FinanceOverview,
  type FinanceSummary,
  financeApi as api,
  type ImportRow,
  type TransactionList,
  type TransactionOp,
  type TransferPair,
} from "./api";
import { buildCategoryTree, type CategoryTree } from "./category-tree";

export type PeriodMode = "month" | "year" | "all";
export interface Period {
  mode: PeriodMode;
  year: number;
  month: number; // 0-11
}
export interface Filter {
  q: string;
  category: string; // "" = all, "none" = uncategorized, else a category id (with its subcategories)
  account: string; // "" = all, "none" = without an account, else an account id
  kind: "" | "income" | "expense" | "transfer";
}

/** What the overview compares the period with (besides the statistic average). */
export type ComparisonKey = "month" | "last_month" | "year" | "last_year" | "all";

/** One column of the comparison: income, expenses and per category, per month. An average is
 *  over the range's completed months, from the first one with transactions on. */
export interface Comparison {
  key: ComparisonKey;
  /** The months it covers (YYYY-MM); none when there is no completed month yet. */
  first: string | null;
  last: string | null;
  months: number;
  average: boolean;
  incomeCents: number;
  expenseCents: number;
  categories: Map<string | null, { incomeCents: number; expenseCents: number }>;
}

export interface I18n {
  t: (key: string, vars?: TVars) => string;
  locale: string;
}

type Toast = (message: string, action?: { label: string; onClick: () => void }) => void;

const PAGE = 200;
const MAX_OPS = 2000; // the most ops POST /finance/transactions takes

function pad(n: number) {
  return String(n).padStart(2, "0");
}

function lastDay(year: number, month: number) {
  return new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
}

function isoDay(d: Date) {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** Today in local time, as YYYY-MM-DD. */
export function today() {
  return isoDay(new Date());
}

/** The months from `a` to `b` (YYYY-MM), both counted. */
function monthsBetween(a: string, b: string) {
  return (+b.slice(0, 4) - +a.slice(0, 4)) * 12 + (+b.slice(5, 7) - +a.slice(5, 7)) + 1;
}

/** "2 transfers and 1 split booking combined". */
export function combinedText(t: I18n["t"], transfers: number, splits: number) {
  const what = [
    transfers ? t("finance.combinedTransfers", { count: transfers }) : "",
    splits ? t("finance.combinedSplits", { count: splits }) : "",
  ]
    .filter(Boolean)
    .join(` ${t("finance.combinedAnd")} `);
  return t("finance.combined", { what });
}

export class FinanceStore {
  overview: FinanceOverview | null = null;
  list: TransactionList | null = null;
  summary: FinanceSummary | null = null;
  /** The columns the overview compares, for the period of `summary`. */
  comparisons: Comparison[] | null = null;
  /** The accounts' balances (by id) at the end of the day `at`; null for all time. */
  balances: { at: string; cents: Record<string, number> } | null = null;
  loadingList = false;
  error: string | null = null;
  period: Period;
  filter: Filter = { q: "", category: "", account: "", kind: "" };
  limit = PAGE;
  /** Transactions ticked in the list, to combine them into a transfer or a split booking. */
  selected = new Set<string>();
  rev = 0;
  readonly readOnly: boolean;
  private i18n: I18n;
  private toast: Toast;
  private listeners = new Set<() => void>();
  private opened = false;
  private listSeq = 0;
  private summarySeq = 0;
  private comparisonSeq = 0;
  private balancesSeq = 0;

  constructor(
    readonly familyId: string,
    opts: { readOnly: boolean; i18n: I18n; toast: Toast },
  ) {
    const now = new Date();
    this.period = { mode: "month", year: now.getFullYear(), month: now.getMonth() };
    this.readOnly = opts.readOnly;
    this.i18n = opts.i18n;
    this.toast = opts.toast;
  }

  private t(key: string, vars?: TVars) {
    return this.i18n.t(key, vars);
  }

  setI18n(i18n: I18n) {
    this.i18n = i18n;
  }

  get locale() {
    return this.i18n.locale;
  }

  subscribe = (fn: () => void) => {
    this.listeners.add(fn);
    return () => {
      this.listeners.delete(fn);
    };
  };

  getRev = () => this.rev;

  private emit() {
    this.rev++;
    for (const fn of this.listeners) fn();
  }

  get currency() {
    return this.overview?.currency ?? "EUR";
  }

  get categories(): Category[] {
    return this.overview?.categories ?? [];
  }

  private treeOf: { categories: Category[]; tree: CategoryTree } | null = null;

  /** The categories as a tree (depth first in `ordered`). */
  get categoryTree(): CategoryTree {
    const categories = this.categories;
    if (this.treeOf?.categories !== categories) {
      this.treeOf = { categories, tree: buildCategoryTree(categories) };
    }
    return this.treeOf.tree;
  }

  categoryById(id: string | null) {
    return id ? this.categories.find((c) => c.id === id) : undefined;
  }

  get accounts(): Account[] {
    return this.overview?.accounts ?? [];
  }

  accountById(id: string | null) {
    return id ? this.accounts.find((a) => a.id === id) : undefined;
  }

  /** The account's balance on the period's balance day (see balanceDay), else now. */
  balanceOf(account: Account) {
    return this.balances?.cents[account.id] ?? account.balanceCents;
  }

  /** Loads the categories and the first page once; later calls do nothing. */
  open() {
    if (this.opened) return;
    this.opened = true;
    void this.loadOverview();
    void this.loadList();
    void this.loadBalances();
  }

  /** Loads only the overview (categories, accounts, settings): the settings page. */
  openSettings() {
    if (!this.overview) void this.loadOverview();
  }

  async loadOverview() {
    try {
      this.overview = await api.overview(this.familyId);
      this.error = null;
    } catch (err) {
      this.error = (err as Error).message;
    }
    this.emit();
  }

  /** The period as a date range (none for "all"). */
  range(period = this.period): { from?: string; to?: string } {
    const { mode, year, month } = period;
    if (mode === "all") return {};
    if (mode === "year") return { from: `${year}-01-01`, to: `${year}-12-31` };
    return {
      from: `${year}-${pad(month + 1)}-01`,
      to: `${year}-${pad(month + 1)}-${lastDay(year, month)}`,
    };
  }

  /** The day whose balances the period shows: its last day, or today while it runs (none for
   *  "all", which shows them now). */
  balanceDay(period = this.period): string | null {
    const { from, to } = this.range(period);
    if (!from || !to) return null;
    const now = today();
    return from <= now && now <= to ? now : to;
  }

  async loadList() {
    const seq = ++this.listSeq;
    this.loadingList = true;
    this.emit();
    const { from, to } = this.range();
    const query: Record<string, string> = { limit: String(this.limit) };
    if (from) query.from = from;
    if (to) query.to = to;
    if (this.filter.q.trim()) query.q = this.filter.q.trim();
    if (this.filter.category) query.category = this.filter.category;
    if (this.filter.account) query.account = this.filter.account;
    if (this.filter.kind) query.kind = this.filter.kind;
    try {
      const list = await api.transactions(this.familyId, query);
      if (seq !== this.listSeq) return; // a newer request is on its way
      this.list = list;
      this.error = null;
      // Keep only what is still shown ticked (e.g. not a row that was just deleted).
      const ids = new Set(list.transactions.map((tx) => tx.id));
      this.selected = new Set([...this.selected].filter((id) => ids.has(id)));
    } catch (err) {
      if (seq !== this.listSeq) return;
      this.error = (err as Error).message;
    }
    this.loadingList = false;
    this.emit();
  }

  async loadBalances() {
    const seq = ++this.balancesSeq;
    const at = this.balanceDay();
    if (!at) {
      this.balances = null;
      this.emit();
      return;
    }
    try {
      const res = await api.accountsAt(this.familyId, at);
      if (seq !== this.balancesSeq) return;
      this.balances = {
        at: res.at,
        cents: Object.fromEntries(res.accounts.map((a) => [a.id, a.balanceCents])),
      };
    } catch (err) {
      if (seq !== this.balancesSeq) return;
      this.error = (err as Error).message;
    }
    this.emit();
  }

  async loadSummary() {
    const seq = ++this.summarySeq;
    const { from, to } = this.range();
    const query: Record<string, string> = {};
    if (from) query.from = from;
    if (to) query.to = to;
    void this.loadComparisons();
    try {
      const summary = await api.summary(this.familyId, query);
      if (seq === this.summarySeq) this.summary = summary;
    } catch (err) {
      this.error = (err as Error).message;
    }
    this.emit();
  }

  /** What the period is compared with: a month with itself and the month before; a year by
   *  its average month with the year before's; all time by its average month. Averages count
   *  only completed months (not the running one), from the first with transactions on. */
  comparisonRanges(period = this.period) {
    const { mode, year, month } = period;
    const now = new Date();
    const done = isoDay(new Date(now.getFullYear(), now.getMonth(), 0)); // last completed day
    const average = (key: ComparisonKey, range: { from?: string; to?: string }) => ({
      key,
      average: true,
      from: range.from,
      to: range.to && range.to < done ? range.to : done,
    });
    if (mode === "month") {
      const prev = month ? { year, month: month - 1 } : { year: year - 1, month: 11 };
      return [
        { key: "month" as const, average: false, ...this.range(period) },
        { key: "last_month" as const, average: false, ...this.range({ mode, ...prev }) },
      ];
    }
    if (mode === "year") {
      return [average("year", this.range(period)), average("last_year", this.range({ ...period, year: year - 1 }))];
    }
    return [average("all", {})];
  }

  async loadComparisons() {
    const seq = ++this.comparisonSeq;
    const load = async ({
      key,
      average,
      from,
      to,
    }: ReturnType<FinanceStore["comparisonRanges"]>[number]): Promise<Comparison> => {
      const none: Comparison = {
        key,
        average,
        first: null,
        last: null,
        months: 0,
        incomeCents: 0,
        expenseCents: 0,
        categories: new Map(),
      };
      if (from && to && to < from) return none; // no completed month yet
      const query: Record<string, string> = {};
      if (from) query.from = from;
      if (to) query.to = to;
      const s = await api.summary(this.familyId, query);
      const last = to!.slice(0, 7);
      const first = average ? s.months[0]?.month : last;
      if (!first) return { ...none, last };
      const months = monthsBetween(first, last);
      const per = (cents: number) => Math.round(cents / months);
      return {
        ...none,
        first,
        last,
        months,
        incomeCents: per(s.incomeCents),
        expenseCents: per(s.expenseCents),
        categories: new Map(
          s.categories.map((c) => [c.categoryId, { incomeCents: per(c.incomeCents), expenseCents: per(c.expenseCents) }]),
        ),
      };
    };
    try {
      const comparisons = await Promise.all(this.comparisonRanges().map(load));
      if (seq === this.comparisonSeq) this.comparisons = comparisons;
    } catch (err) {
      if (seq === this.comparisonSeq) this.error = (err as Error).message;
    }
    this.emit();
  }

  private reload() {
    if (!this.opened) return; // nothing shown yet: it loads when the page opens
    void this.loadList();
    void this.loadBalances();
    if (this.summary) void this.loadSummary();
  }

  /** After transactions changed: what is shown and the account balances. */
  private changed() {
    if (!this.opened) return;
    this.reload();
    void this.loadOverview();
  }

  /** Reloads what is shown, e.g. after the assistant changed transactions. */
  refresh() {
    this.changed();
  }

  /** Reloads the categories, and what is shown since they name its transactions. */
  refreshCategories() {
    void this.loadOverview();
    this.reload();
  }

  setPeriod(period: Partial<Period>) {
    this.period = { ...this.period, ...period };
    this.comparisons = null; // they belong to the period before
    this.limit = PAGE;
    this.selected = new Set();
    this.reload();
    this.emit();
  }

  /** The previous / next month or year. */
  step(dir: -1 | 1) {
    const { mode, year, month } = this.period;
    if (mode === "year") this.setPeriod({ year: year + dir });
    else if (mode === "month") {
      const m = month + dir;
      this.setPeriod({ year: year + Math.floor(m / 12), month: (m + 12) % 12 });
    }
  }

  setFilter(filter: Partial<Filter>) {
    this.filter = { ...this.filter, ...filter };
    this.limit = PAGE;
    this.selected = new Set();
    void this.loadList();
  }

  toggleSelected(id: string, on: boolean) {
    const next = new Set(this.selected);
    if (on) next.add(id);
    else next.delete(id);
    this.selected = next;
    this.emit();
  }

  clearSelection() {
    if (!this.selected.size) return;
    this.selected = new Set();
    this.emit();
  }

  showMore() {
    this.limit += PAGE;
    void this.loadList();
  }

  /** Applies transaction ops; the toast offers to undo them. Resolves to the new ids. */
  async change(ops: TransactionOp[], message: string): Promise<string[] | null> {
    try {
      const res = await api.changeTransactions(this.familyId, ops);
      this.changed();
      this.toast(message, { label: this.t("finance.undo"), onClick: () => void this.undo(res.inverse) });
      return res.added;
    } catch (err) {
      this.toast(this.t("finance.saveFailed", { msg: (err as Error).message }));
      return null;
    }
  }

  private async undo(inverse: TransactionOp[]) {
    try {
      for (let i = 0; i < inverse.length; i += MAX_OPS) {
        await api.changeTransactions(this.familyId, inverse.slice(i, i + MAX_OPS));
      }
      this.changed();
      this.toast(this.t("finance.undone"));
    } catch (err) {
      this.toast(this.t("finance.saveFailed", { msg: (err as Error).message }));
    }
  }

  // ------------------------------------------------------------- split bookings

  /** Makes transactions parts of a booking (e.g. an order's items of a "Splitbuchung"): they
   *  count on their own, the booking only with what they leave over. */
  async split(bookingId: string, partIds: string[]) {
    const ok = await this.change([{ action: "split", id: bookingId, ids: partIds }], this.t("finance.splitDone"));
    if (ok) this.clearSelection();
    return ok;
  }

  /** Takes a part out of its booking, or (on a booking) all of its parts. */
  unsplit(id: string) {
    const part = this.list?.transactions.find((tx) => tx.id === id)?.splitOf;
    return this.change(
      [{ action: "unsplit", ids: [id] }],
      this.t(part ? "finance.unsplitPartDone" : "finance.unsplitDone"),
    );
  }

  // ------------------------------------------------------------- transfers

  /** Combines transactions into one transfer: they count once, as their sum. */
  async link(ids: string[]) {
    const ok = await this.change([{ action: "link", ids }], this.t("finance.linked"));
    if (ok) this.clearSelection();
    return ok;
  }

  /** Combines each pair into a transfer of its own, in one undoable step. */
  linkPairs(pairs: string[][]) {
    return this.change(
      pairs.map((ids) => ({ action: "link", ids })),
      this.t("finance.linkedPairs", { count: pairs.length }),
    );
  }

  /** Splits the transfer a transaction belongs to back into normal transactions. */
  unlink(id: string) {
    return this.change([{ action: "unlink", id }], this.t("finance.unlinked"));
  }

  /** Combines the period's split bookings with their parts, then every likely transfer, at
   *  once; the toast can undo it. */
  async autoCombineTransfers() {
    try {
      const res = await api.autoTransfers(this.familyId, this.range());
      if (!res.linked && !res.splits) {
        this.toast(this.t("finance.nothingToCombine"));
        return res;
      }
      this.changed();
      this.toast(combinedText(this.i18n.t, res.linked, res.splits), {
        label: this.t("finance.undo"),
        onClick: () => void this.undo(res.inverse),
      });
      return res;
    } catch (err) {
      this.toast(this.t("finance.saveFailed", { msg: (err as Error).message }));
      return null;
    }
  }

  /** Transactions of the period that look like transfers between two accounts. */
  async suggestions(): Promise<TransferPair[]> {
    const { from, to } = this.range();
    const query: Record<string, string> = {};
    if (from) query.from = from;
    if (to) query.to = to;
    return (await api.transferSuggestions(this.familyId, query)).pairs;
  }

  /** A dry run of an import: which rows are there already, how much would be combined. */
  checkImport(rows: ImportRow[], accountId: string | undefined, autoTransfers: boolean) {
    return api.importTransactions(this.familyId, rows, true, accountId, autoTransfers);
  }

  async importRows(rows: ImportRow[], accountId?: string, autoTransfers = false) {
    const res = await api.importTransactions(this.familyId, rows, false, accountId, autoTransfers);
    this.changed();
    const skipped = res.duplicates.length;
    if (res.ids.length) {
      const transfers = res.transfers ?? 0;
      const splits = res.splits ?? 0;
      const message = [
        this.t("finance.imported", { count: res.added }),
        skipped ? this.t("finance.importedSkipped", { n: skipped }) : "",
        transfers || splits ? `· ${combinedText(this.i18n.t, transfers, splits)}` : "",
      ]
        .filter(Boolean)
        .join(" ");
      this.toast(message, {
        label: this.t("finance.undo"),
        onClick: () => void this.undo([{ action: "delete", ids: res.ids }]),
      });
    } else this.toast(this.t("finance.importedNone", { n: skipped }));
    return res;
  }

  // ------------------------------------------------------------- categories + settings

  private async withOverview<T>(fn: () => Promise<T>): Promise<T | null> {
    try {
      const out = await fn();
      await this.loadOverview();
      return out;
    } catch (err) {
      this.toast(this.t("finance.saveFailed", { msg: (err as Error).message }));
      await this.loadOverview();
      return null;
    }
  }

  addCategory(c: Parameters<typeof api.addCategory>[1]) {
    return this.withOverview(() => api.addCategory(this.familyId, c));
  }

  updateCategory(id: string, patch: Partial<Category>) {
    // Show it right away; the reload corrects it if saving fails.
    if (this.overview) {
      this.overview = {
        ...this.overview,
        categories: this.categories.map((c) => (c.id === id ? { ...c, ...patch } : c)),
      };
      this.emit();
    }
    return this.withOverview(() => api.updateCategory(this.familyId, id, patch));
  }

  /** Moves the category up or down among its siblings. */
  moveCategory(id: string, dir: -1 | 1) {
    const tree = this.categoryTree;
    const parent = tree.parentOf(id);
    const siblings = (parent ? tree.byId.get(parent.id)!.children : tree.roots).map((n) => n.category);
    const i = siblings.findIndex((c) => c.id === id);
    const j = i + dir;
    if (i < 0 || j < 0 || j >= siblings.length) return Promise.resolve(null);
    [siblings[i], siblings[j]] = [siblings[j], siblings[i]];
    // Siblings get the positions 0, 1, 2 …: only those that change are saved.
    const changed = siblings.map((c, position) => ({ ...c, position })).filter((c, k) => c.position !== siblings[k].position);
    const byId = new Map(changed.map((c) => [c.id, c]));
    if (this.overview) {
      this.overview = { ...this.overview, categories: this.categories.map((c) => byId.get(c.id) ?? c) };
    }
    this.emit();
    return this.withOverview(() =>
      Promise.all(changed.map((c) => api.updateCategory(this.familyId, c.id, { position: c.position }))),
    );
  }

  /** Makes the category a subcategory of `parentId` (null: top level), with its own. */
  async moveCategoryTo(id: string, parentId: string | null) {
    await this.withOverview(() => api.updateCategory(this.familyId, id, { parentId }));
  }

  /** Deletes the category; its subcategories and transactions move to its parent. */
  async deleteCategory(id: string) {
    await this.withOverview(() => api.deleteCategory(this.familyId, id));
    if (this.filter.category === id) this.setFilter({ category: "" });
    else this.reload();
  }

  // ------------------------------------------------------------- accounts

  addAccount(a: Parameters<typeof api.addAccount>[1]) {
    return this.withOverview(() => api.addAccount(this.familyId, a));
  }

  async updateAccount(id: string, patch: Parameters<typeof api.updateAccount>[2]) {
    // Show it right away; the reload corrects it (and the balance) if saving fails.
    if (this.overview) {
      this.overview = {
        ...this.overview,
        accounts: this.accounts.map((a) => (a.id === id ? { ...a, ...patch } : a)),
      };
      this.emit();
    }
    const out = await this.withOverview(() => api.updateAccount(this.familyId, id, patch));
    // A new opening balance moves the balances on every day.
    if (patch.openingCents !== undefined && this.opened) void this.loadBalances();
    return out;
  }

  moveAccount(i: number, dir: -1 | 1) {
    const list = [...this.accounts];
    const j = i + dir;
    if (j < 0 || j >= list.length) return Promise.resolve(null);
    [list[i], list[j]] = [list[j], list[i]];
    if (this.overview) this.overview = { ...this.overview, accounts: list };
    this.emit();
    return this.withOverview(() =>
      Promise.all([
        api.updateAccount(this.familyId, list[i].id, { position: i }),
        api.updateAccount(this.familyId, list[j].id, { position: j }),
      ]),
    );
  }

  async deleteAccount(id: string) {
    await this.withOverview(() => api.deleteAccount(this.familyId, id));
    if (this.filter.account === id) this.setFilter({ account: "" });
    else this.reload();
  }

  addDefaultCategories() {
    return this.withOverview(() => api.defaultCategories(this.familyId, this.i18n.locale));
  }

  async setCurrency(currency: string) {
    await this.withOverview(() => api.settings(this.familyId, { currency }));
    this.reload();
  }

  /** Deletes all transactions, categories and settings; there is no undo. */
  async clearAll() {
    const out = await this.withOverview(() => api.clear(this.familyId));
    this.reload();
    if (out) this.toast(this.t("finance.cleared"));
  }

  /** The category the shopping lists read their spending from (phase 7); null: the default. */
  setGroceriesCategory(groceriesCategoryId: string | null) {
    return this.withOverview(() => api.settings(this.familyId, { groceriesCategoryId }));
  }

  /** Sets the statistic average the overview compares with; null removes it. */
  setBenchmark(benchmark: Benchmark | null) {
    return this.withOverview(() => api.settings(this.familyId, { benchmark }));
  }

  get mappings(): CsvMapping[] {
    return (this.overview?.csvMappings ?? []) as CsvMapping[];
  }

  /** Remembers how a bank's files map (by their header), newest first. */
  saveMapping(mapping: CsvMapping) {
    if (!mapping.signature) return Promise.resolve(null);
    const rest = this.mappings.filter((m) => m.signature !== mapping.signature);
    return this.withOverview(() => api.settings(this.familyId, { csvMappings: [mapping, ...rest].slice(0, 20) }));
  }

  deleteMapping(signature: string) {
    const rest = this.mappings.filter((m) => m.signature !== signature);
    return this.withOverview(() => api.settings(this.familyId, { csvMappings: rest }));
  }
}
