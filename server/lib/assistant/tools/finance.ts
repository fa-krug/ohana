// The assistant's finance tools: list, sum up and analyze transactions, and change them, the
// categories and the statistic average (with the same validation as the REST API). Every
// change comes with undo steps: requests against the family's own API that put things back.

import { HttpError, objectOf } from "@/lib/api/http";
import { isValidDate } from "@/lib/calendar/dates";
import { categoryTree } from "@/lib/finance/category-tree";
import {
  applyTransactionOps,
  autoCombine,
  benchmarkOf,
  changedCategories,
  cleanBenchmark,
  financeSummary,
  findCategory,
  findTransactions,
  listAccounts,
  netItems,
  newCategory,
  publicCategory,
  publicTransaction,
  transferPairs,
} from "@/lib/finance/finance";
import type { AccountRow, CategoryRow, FinanceStore as Store } from "@/lib/finance/store";
import { analyzeTransactions, TX_DIMENSIONS, TX_SORTS, TX_STATS } from "../analytics";
import {
  choices,
  CONFIRM_TRANSACTIONS,
  DEFAULT_GROUPS,
  fitting,
  MAX_GROUPS,
  MAX_LABEL,
  MAX_QUERIES,
  MAX_TOOL_RESULT,
  MAX_TX_DESCRIPTION,
  MAX_TX_ROWS,
  needConfirm,
  opsSchema,
  PHRASES,
  range,
  type Tool,
  TX_COLUMNS,
} from "./common";

type CategoryTotals = {
  categoryId: string | null;
  incomeCents: number;
  expenseCents: number;
  count: number;
};

/** A summary's totals per category (its own transactions) in the order of the category tree,
 *  with the path, and for a category with subcategories also the totals with them. */
function categoryTotals(rows: CategoryTotals[], categories: CategoryRow[]) {
  const tree = categoryTree(categories);
  const own = new Map(rows.map((r) => [r.categoryId, r]));
  const out: Record<string, unknown>[] = [];
  for (const c of tree.ordered) {
    const sub = [...tree.subtree(c.id)].flatMap((id) => own.get(id) ?? []);
    if (!sub.length) continue;
    const o = own.get(c.id);
    const sum = (k: "incomeCents" | "expenseCents" | "count") => sub.reduce((n, r) => n + r[k], 0);
    out.push({
      categoryId: c.id,
      path: tree.path(c.id),
      incomeCents: o?.incomeCents ?? 0,
      expenseCents: o?.expenseCents ?? 0,
      count: o?.count ?? 0,
      ...(tree.children(c.id).length
        ? {
          withSubcategories: {
            incomeCents: sum("incomeCents"),
            expenseCents: sum("expenseCents"),
            count: sum("count"),
          },
        }
        : {}),
    });
  }
  return [...out, ...rows.filter((r) => !r.categoryId || !tree.byId.has(r.categoryId))];
}


const RANGE_SCHEMA = {
  type: "object",
  properties: { lowCents: { type: "integer" }, highCents: { type: "integer" } },
};


/** The filters and options of one analysis (analyze_transactions, also per query). */
const ANALYSIS_PROPERTIES = {
  from: { type: "string" },
  to: { type: "string" },
  account: { type: "string" },
  category: { type: "string" },
  kind: { type: "string", enum: ["income", "expense", "transfer"] },
  q: { type: "string" },
  groupBy: {
    type: "array",
    items: { type: "string", enum: [...TX_DIMENSIONS] },
    description: "Default: month",
  },
  categoryLevel: {
    type: "integer",
    description: "With groupBy category: count each transaction for its category's " +
      "ancestor at this level (1 = top level). Default: its own category",
  },
  stats: { type: "array", items: { type: "string", enum: [...TX_STATS] } },
  sortBy: { type: "string", enum: [...TX_SORTS] },
  order: { type: "string", enum: ["asc", "desc"] },
  limit: { type: "integer", description: `Groups at most, default ${DEFAULT_GROUPS}` },
};

/** One analysis of analyze_transactions, its groups cut to fit into `max` characters. */
async function analysis(
  store: Store,
  familyId: string,
  args: Record<string, unknown>,
  categories: CategoryRow[],
  accounts: AccountRow[],
  max = MAX_TOOL_RESULT,
) {
  const query = new URLSearchParams();
  for (const k of ["from", "to", "account", "category", "kind", "q"]) {
    if (typeof args[k] === "string" && args[k]) query.set(k, args[k] as string);
  }
  const asked = choices(args.groupBy, TX_DIMENSIONS, "groupBy", 2);
  const groupBy = asked?.length ? asked : ["month" as const];
  const stats = choices(args.stats, TX_STATS, "stats") ?? [];
  const [sortBy] = choices(args.sortBy, TX_SORTS, "sortBy", 1) ?? [];
  const [order] = choices(args.order, ["asc", "desc"] as const, "order", 1) ?? [];
  const level = args.categoryLevel;
  if (level !== undefined && level !== null && (!Number.isInteger(level) || +level < 1)) {
    throw new HttpError(400, "categoryLevel must be a whole number from 1");
  }
  const { rows, links } = await findTransactions(store, familyId, query);
  const res = analyzeTransactions({
    items: netItems(rows, links),
    groupBy,
    stats,
    sortBy,
    order,
    categoryLevel: (level as number | null) ?? undefined,
    categories,
    accounts,
    from: query.get("from") ?? undefined,
    to: query.get("to") ?? undefined,
  });
  const limit = Math.min(MAX_GROUPS, Math.max(1, Number(args.limit) || DEFAULT_GROUPS));
  const head = { groupBy, total: res.total, perGroup: res.perGroup, groupCount: 0 };
  const groups = fitting(head, res.groups.slice(0, limit), max);
  return {
    groupBy,
    total: res.total,
    ...(res.perGroup ? { perGroup: res.perGroup } : {}),
    groupCount: res.groups.length,
    groups,
    ...(groups.length < res.groups.length ? { more: res.groups.length - groups.length } : {}),
  };
}


export const financeTools: Record<string, Tool> = {
  list_transactions: {
    spec: {
      name: "list_transactions",
      description:
        'Lists transactions (newest first) with totals, as rows of `columns`: as many as fit, long descriptions shortened. If `nextOffset` is set there are more: call again with that offset. For totals per month or category use finance_summary instead. Amounts are integer cents, negative = money out. Legs of a transfer between the family\'s accounts share a transferId; totals count a transfer once by its net (500 moved between two accounts counts 0). A part of a split booking (e.g. an order line of an Amazon "Splitbuchung") has the booking\'s id as splitOf; totals count the parts and only what is left of the booking. Filters: from/to (YYYY-MM-DD), account (id, name or "none"), category (id, name, path like "Food > Groceries", or "none"; includes its subcategories), kind (income | expense | transfer: legs of transfers), q (text in payee, description, note).',
      parameters: {
        type: "object",
        properties: {
          from: { type: "string" },
          to: { type: "string" },
          account: { type: "string" },
          category: { type: "string" },
          kind: { type: "string", enum: ["income", "expense", "transfer"] },
          q: { type: "string" },
          offset: { type: "integer", description: "Rows to skip, from nextOffset" },
          limit: { type: "integer", description: "Rows at most; leave out to get as many as fit" },
        },
      },
    },
    async run(args, { finance: store, familyId }) {
      const query = new URLSearchParams();
      for (const k of ["from", "to", "account", "category", "kind", "q"]) {
        if (typeof args[k] === "string" && args[k]) query.set(k, args[k] as string);
      }
      const { rows, links, incomeCents, expenseCents } = await findTransactions(
        store,
        familyId,
        query,
      );
      const offset = Math.max(0, Math.floor(Number(args.offset)) || 0);
      const limit = Math.min(MAX_TX_ROWS, Math.max(1, Number(args.limit) || MAX_TX_ROWS));
      const head = { total: rows.length, incomeCents, expenseCents, columns: TX_COLUMNS };
      // Rows until the result is about to be cut off (room left for offset and nextOffset).
      let size = JSON.stringify(head).length + 60;
      const out: unknown[][] = [];
      for (const t of rows.slice(offset, offset + limit)) {
        const p = publicTransaction(t, links);
        const description = p.description.length > MAX_TX_DESCRIPTION
          ? p.description.slice(0, MAX_TX_DESCRIPTION) + "…"
          : p.description;
        const row = [
          p.id,
          p.date,
          p.amountCents,
          p.payee,
          description,
          p.categoryId,
          p.accountId,
          p.transferId,
          p.splitOf,
          p.note,
        ];
        size += JSON.stringify(row).length + 1;
        if (size > MAX_TOOL_RESULT && out.length) break;
        out.push(row);
      }
      const next = offset + out.length;
      return {
        result: {
          ...head,
          offset,
          rows: out,
          ...(next < rows.length ? { nextOffset: next } : {}),
        },
        summary: `${rows.length} transactions`,
      };
    },
  },

  finance_summary: {
    spec: {
      name: "finance_summary",
      description:
        "Income and expenses (integer cents) per month and per category between two days (a transfer between the family's accounts counts once by its net), plus the currency, the categories and the accounts with their current balances (balanceCents) and their balances at the end of `to` (balanceAtToCents). Categories nest: per category its own transactions, and for one with subcategories also withSubcategories (it and all below it).",
      parameters: {
        type: "object",
        properties: { from: { type: "string" }, to: { type: "string" } },
        required: ["from", "to"],
      },
    },
    async run(args, { finance: store, familyId }) {
      const { from, to } = range(args);
      const [summary, categories, accounts, atTo] = await Promise.all([
        financeSummary(store, familyId, from, to),
        store.listCategories(familyId),
        listAccounts(store, familyId),
        store.accountTotals(familyId, to),
      ]);
      const withAtTo = accounts.map((a) => ({
        ...a,
        balanceAtToCents: a.openingCents + (atTo.get(a.id) ?? 0),
      }));
      return {
        result: {
          ...summary,
          categories: categoryTotals(summary.categories, categories),
          categoryNames: categories.map(publicCategory),
          accounts: withAtTo,
        },
        summary: `${from} – ${to}`,
      };
    },
  },

  analyze_transactions: {
    spec: {
      name: "analyze_transactions",
      description:
        'Totals and statistics of transactions per group, computed exactly (use it instead of adding up list_transactions): up to 2 of groupBy: month, quarter, year, week (ISO), weekday, day, category, account, payee (similar spellings together), kind (income / expense). Each group has count, incomeCents, expenseCents, netCents, and the asked stats of its single amounts (avg, median, min, max, stddev; in cents, negative = out). With one groupBy, perGroup has the average and median group (e.g. the average month; empty months count as 0). Counted like all totals: a transfer between the family\'s accounts once by its net, a split booking by its parts. Categories nest ("Food > Groceries"): by default a transaction counts for its own category; with categoryLevel (1 = top level, 2 = second level …) for its category\'s ancestor at that level, or its own category if that isn\'t as deep; nested groups have categoryPath. Same filters as list_transactions (from, to, account, category with its subcategories, kind, q). Time groups come in order, others largest first; sortBy: key, total (income + expenses), count, income, expense, net; order: asc or desc. One call usually covers a whole question: groupBy category, account or kind gives every category, account or kind at once (with year or month as the second dimension, per period). To compare different periods or filters, don\'t call once each: give `queries`, up to 10 analyses with their own filters and options (and a label, given back) in one call; what is set outside queries applies to all of them, e.g. {"groupBy": ["category"], "categoryLevel": 1, "kind": "expense", "queries": [{"label": "2025", "from": "2025-01-01", "to": "2025-10-25"}, {"label": "2026", "from": "2026-01-01", "to": "2026-10-25"}]}. The result then has results: one per query, in order.',
      parameters: {
        type: "object",
        properties: {
          ...ANALYSIS_PROPERTIES,
          queries: {
            type: "array",
            description: `Up to ${MAX_QUERIES} analyses in one call, each with any of the ` +
              "options above and a label",
            items: {
              type: "object",
              properties: { label: { type: "string" }, ...ANALYSIS_PROPERTIES },
            },
          },
        },
      },
    },
    async run(args, { finance: store, familyId }) {
      const [categories, accounts] = await Promise.all([
        store.listCategories(familyId),
        store.listAccounts(familyId),
      ]);
      const analyze = (a: Record<string, unknown>, max?: number) =>
        analysis(store, familyId, a, categories, accounts, max);
      if (args.queries === undefined || args.queries === null) {
        const result = await analyze(args);
        return { result, summary: `${result.groupCount} groups` };
      }
      const { queries, ...shared } = args;
      if (!Array.isArray(queries) || !queries.length || queries.length > MAX_QUERIES) {
        throw new HttpError(400, `queries must be a list of 1 to ${MAX_QUERIES} analyses`);
      }
      const list = queries.map((q) => ({ ...shared, ...objectOf(q, "Each query") }));
      // The analyses share the tool result.
      const max = Math.floor(MAX_TOOL_RESULT / list.length) - 40;
      const results = await Promise.all(list.map(async (q) => {
        const label = typeof q.label === "string" && q.label.trim()
          ? { label: q.label.trim().slice(0, MAX_LABEL) }
          : {};
        try {
          return { ...label, ...(await analyze(q, max)) };
        } catch (err) {
          // One bad query doesn't spoil the others.
          if (err instanceof HttpError) return { ...label, error: err.message };
          throw err;
        }
      }));
      return {
        result: { results },
        summary: `${results.length} ${results.length === 1 ? "analysis" : "analyses"}`,
      };
    },
  },

  manage_categories: {
    write: true,
    spec: {
      name: "manage_categories",
      description:
        'Adds, changes, moves or deletes finance categories. Categories nest to any depth (e.g. "Food > Groceries > Bakery"); transactions can be on any level, and a category\'s totals include its subcategories. "add": name, parent (id, name or path; leave out for a top-level category), kind (expense | income | both, default expense; only for top-level ones, a subcategory has its top-level category\'s), color (#rrggbb), icon (one emoji). "update": category (id, name or path) and any of name, parent (moves it with its subcategories; "" = top level), kind (top level only, its subcategories follow), color, icon. "delete": category (its subcategories and transactions move to its parent; for a top-level one the subcategories become top-level and the transactions uncategorized; needs confirmed). A name that several categories have needs the path.',
      parameters: {
        type: "object",
        properties: {
          action: { type: "string", enum: ["add", "update", "delete"] },
          category: { type: "string" },
          parent: { type: "string" },
          name: { type: "string" },
          kind: { type: "string", enum: ["expense", "income", "both"] },
          color: { type: "string" },
          icon: { type: "string" },
          confirmed: { type: "boolean" },
        },
        required: ["action"],
      },
    },
    async run(args, { finance: store, familyId, lang }) {
      const categories = await store.listCategories(familyId);
      const path = (id: string) => `/finance/categories/${encodeURIComponent(id)}`;
      switch (args.action) {
        case "add": {
          const row = newCategory(familyId, categories, {
            color: "#64748b",
            ...args,
            parentId: args.parent,
          });
          await store.upsertCategories([row]);
          return {
            result: publicCategory(row),
            summary: `Added “${row.name}”`,
            change: {
              kind: "categories",
              summary: PHRASES[lang].categoryAdded(row.name),
              undo: [{ method: "DELETE", path: path(row.id) }],
            },
          };
        }
        case "update": {
          const current = findCategory(categories, args.category);
          const { name, kind, color, icon, parent } = args;
          const changed = changedCategories(categories, current, {
            name,
            kind,
            color,
            icon,
            parentId: parent,
          });
          await store.upsertCategories(changed);
          const next = changed[0];
          return {
            result: publicCategory(next),
            summary: `Changed “${next.name}”`,
            change: {
              kind: "categories",
              summary: PHRASES[lang].categoryChanged(current.name),
              undo: [{
                method: "PATCH",
                path: path(current.id),
                body: {
                  name: current.name,
                  kind: current.kind,
                  color: current.color,
                  icon: current.icon,
                  parentId: current.parent_id ?? null,
                  position: current.position,
                },
              }],
            },
          };
        }
        case "delete": {
          const current = findCategory(categories, args.category);
          needConfirm(
            args,
            current.parent_id
              ? `Deleting “${current.name}” moves its subcategories and transactions to its parent and can't be undone.`
              : `Deleting “${current.name}” leaves its transactions uncategorized, makes its subcategories top-level ones and can't be undone.`,
          );
          await store.deleteCategory(familyId, current.id);
          return { result: { deleted: current.id }, summary: `Deleted “${current.name}”` };
        }
      }
      throw new HttpError(400, "action must be add, update or delete");
    },
  },

  set_statistic_average: {
    write: true,
    spec: {
      name: "set_statistic_average",
      description:
        "Sets the statistic average that the finance overview compares the family's months with, e.g. a statistics office's figures on household income and spending for a household like this one (search the web for current figures and name the source and year in label). Every amount is a range per month in integer cents, not negative: {lowCents, highCents}, e.g. the typical span between lower and upper households, or the same twice for a single average. income, expense, and categories: [{category (id, name or path), lowCents, highCents}] for the family's categories (top-level ones show in the overview; one without its own range sums up those of its subcategories). Leave out what isn't known. It replaces the whole average; clear: true removes it (the overview then doesn't show it).",
      parameters: {
        type: "object",
        properties: {
          label: { type: "string", description: "Where the numbers come from, e.g. the source" },
          income: RANGE_SCHEMA,
          expense: RANGE_SCHEMA,
          categories: {
            type: "array",
            items: {
              type: "object",
              properties: { category: { type: "string" }, ...RANGE_SCHEMA.properties },
              required: ["category"],
            },
          },
          clear: { type: "boolean" },
        },
      },
    },
    async run(args, { finance: store, familyId, lang }) {
      const [settings, categories] = await Promise.all([
        store.getFinanceSettings(familyId),
        store.listCategories(familyId),
      ]);
      const benchmark = args.clear === true ? null : cleanBenchmark(
        {
          label: args.label,
          income: args.income,
          expense: args.expense,
          categories: args.categories,
        },
        categories,
      );
      await store.saveFinanceSettings({
        family_id: familyId,
        currency: "EUR",
        csv_mappings: [],
        ...settings,
        benchmark,
      });
      return {
        result: { benchmark },
        summary: benchmark ? "Set" : "Removed",
        change: {
          kind: "benchmark",
          summary: PHRASES[lang][benchmark ? "benchmarkSet" : "benchmarkCleared"],
          undo: [{
            method: "PATCH",
            path: "/finance/settings",
            body: { benchmark: benchmarkOf(settings, categories) },
          }],
        },
      };
    },
  },

  change_transactions: {
    write: true,
    spec: {
      name: "change_transactions",
      description:
        'Adds, changes, deletes, links, unlinks, splits or unsplits transactions. Ops: {"action": "add", "date", "amountCents" (integer, negative = money out), "payee", "description", "categoryId" (id or name), "accountId" (id or name), "note"}, {"action": "update", "id", ...fields}, {"action": "delete", "ids": [...]}, {"action": "link", "ids": [at least 2]}: the transactions become the legs of one transfer between the family\'s accounts (e.g. 500 out of checking and 500 into savings), counted once by their net, {"action": "unlink", "ids": [...]}: dissolves the transfers these transactions belong to, {"action": "split", "id": "<booking>", "ids": [parts]}: the transactions become parts of the booking (e.g. the order lines the bank lists next to an Amazon "Splitbuchung"); totals count the parts with their categories and only what is left of the booking, {"action": "unsplit", "ids": [...]}: parts become normal transactions again (for a booking: all of its parts).',
      parameters: opsSchema({
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: ["add", "update", "delete", "link", "unlink", "split", "unsplit"],
          },
          id: { type: "string" },
          ids: { type: "array", items: { type: "string" } },
          date: { type: "string" },
          amountCents: { type: "integer" },
          payee: { type: "string" },
          description: { type: "string" },
          categoryId: { type: ["string", "null"] },
          accountId: { type: ["string", "null"] },
          transferId: {
            type: ["string", "null"],
            description: "Rarely needed: use link / unlink to combine or split transfers.",
          },
          note: { type: "string" },
        },
        required: ["action"],
      }),
    },
    async run(args, { finance: store, familyId, lang }) {
      if (!Array.isArray(args.ops)) throw new HttpError(400, "ops must be an array");
      const ops = args.ops.map((o) => objectOf(o, "Each op"));
      const deletes = ops.filter((o) => o.action === "delete")
        .reduce((n, o) => n + (Array.isArray(o.ids) ? o.ids.length : 1), 0);
      if (deletes) needConfirm(args, `This deletes ${deletes} transactions.`);
      if (ops.length > CONFIRM_TRANSACTIONS) {
        needConfirm(args, `This changes ${ops.length} transactions.`);
      }
      const res = await applyTransactionOps(store, familyId, ops);
      return {
        result: { ok: true, changed: res.changed, added: res.added },
        summary: `${res.changed} transactions changed`,
        change: res.changed
          ? {
            kind: "transactions",
            summary: PHRASES[lang].transactions(res.changed),
            undo: [{ method: "POST", path: "/finance/transactions", body: { ops: res.inverse } }],
          }
          : undefined,
      };
    },
  },

  combine_transfers: {
    write: true,
    spec: {
      name: "combine_transfers",
      description:
        'Combines what belongs together, like the app\'s Auto-combine: first split bookings (order lines without a payee that name an order, "Bestellnr. 306-…", all become parts of the booking on the same account that names the same order, of the same day or else the closest within 4 days, also a booking already split; a booking marked "Splitbuchung" takes the transactions of the same day, account and merchant as its parts; so they don\'t count twice), then transfers between the family\'s accounts (money out of one account and the same amount into another within 4 days, not yet combined), so each counts once by its net (0). from/to (YYYY-MM-DD) limit the range; without them the whole history.',
      parameters: {
        type: "object",
        properties: {
          from: { type: "string" },
          to: { type: "string" },
          confirmed: {
            type: "boolean",
            description: "Set only after the user confirmed a big change you described to them.",
          },
        },
      },
    },
    async run(args, { finance: store, familyId, lang }) {
      for (const k of ["from", "to"]) {
        if (args[k] !== undefined && !isValidDate(args[k])) {
          throw new HttpError(400, "from/to must be YYYY-MM-DD");
        }
      }
      const from = args.from as string | undefined, to = args.to as string | undefined;
      const pairs = await transferPairs(store, familyId, from, to);
      if (pairs.length > CONFIRM_TRANSACTIONS / 2) {
        needConfirm(args, `This combines ${pairs.length} transfers.`);
      }
      const res = await autoCombine(store, familyId, from, to);
      const phrases = [
        ...(res.splits ? [PHRASES[lang].splits(res.splits)] : []),
        ...(res.linked || !res.splits ? [PHRASES[lang].transfers(res.linked)] : []),
      ];
      return {
        result: { ok: true, linked: res.linked, splits: res.splits },
        summary: `${res.linked} transfers and ${res.splits} split bookings combined`,
        change: res.changed
          ? {
            kind: "transactions",
            summary: phrases.join(", "),
            undo: [{ method: "POST", path: "/finance/transactions", body: { ops: res.inverse } }],
          }
          : undefined,
      };
    },
  },

};
