// family-planner: the finances (family_settings, finance_categories, finance_accounts,
// transactions). Ids are kept: categories and accounts are unique within their family, and
// transactions keep their uuid, transfer id (the legs of a transfer), split_of (the parts of a
// split booking) and import hash (so a bank statement isn't imported twice later).
//
// The references inside a family are composite foreign keys (lib/db/schema/finance.ts); the
// import's foreign keys are deferred, but the rows still go in the order the store uses:
// parents before their subcategories, bookings before their parts. A reference to a row that
// isn't in the dump (family-planner's foreign keys make that unlikely) is cleared and reported.
import { finAccounts, finCategories, finSettings, finTransactions } from "@/lib/db/schema";
import { categoryTree } from "@/lib/finance/category-tree";
import { CATEGORY_KINDS, type CategoryKind, type CategoryRow } from "@/lib/finance/store";
import { pgDate, pgDay, pgInt, type PgRow } from "../pgdump";
import type { ImportContext } from "../types";
import { fpRows } from "./source";

/** The family's rows of `rows`, grouped by Ohana family id; rows of families that aren't
 *  imported are reported as skipped. */
function byFamily(ctx: ImportContext, table: string, rows: PgRow[], key: (r: PgRow) => string): Map<string, PgRow[]> {
  const out = new Map<string, PgRow[]>();
  for (const r of rows) {
    const familyId = ctx.familyIds.familyPlanner.get(r.family_id ?? "");
    if (!familyId) {
      ctx.skip("familyPlanner", table, `${r.family_id}/${key(r)}`, "its family isn't imported");
      continue;
    }
    out.set(familyId, [...(out.get(familyId) ?? []), r]);
  }
  return out;
}

/** A jsonb column as compact JSON text, or `fallback` when it is missing or not valid JSON. */
function jsonText(v: string | null | undefined, valid: (x: unknown) => boolean, fallback: string | null): string | null {
  if (!v) return fallback;
  try {
    const parsed: unknown = JSON.parse(v);
    return valid(parsed) ? JSON.stringify(parsed) : fallback;
  } catch {
    return fallback;
  }
}

const isKind = (v: string | null | undefined): v is CategoryKind => CATEGORY_KINDS.includes(v as CategoryKind);

export function importFamilyPlannerFinance(ctx: ImportContext): void {
  const src = ctx.sources.familyPlanner;
  if (!src) return;
  const { db } = ctx;

  for (const [familyId, rows] of byFamily(ctx, "family_settings", fpRows(src, "family_settings"), () => "settings")) {
    const s = rows[0];
    const currency = (s.currency ?? "").trim().toUpperCase();
    db.insert(finSettings)
      .values({
        familyId,
        currency: /^[A-Z]{3}$/.test(currency) ? currency : "EUR",
        csvMappings: jsonText(s.csv_mappings, Array.isArray, "[]")!,
        benchmark: jsonText(s.benchmark, (x) => typeof x === "object" && x !== null && !Array.isArray(x), null),
      })
      .run();
  }

  const categories = new Map<string, Set<string>>();
  for (const [familyId, rows] of byFamily(ctx, "finance_categories", fpRows(src, "finance_categories"), (r) => r.id ?? "")) {
    const list: CategoryRow[] = rows.map((c) => ({
      family_id: familyId,
      id: c.id!,
      name: c.name ?? "",
      color: c.color ?? "#64748b",
      icon: c.icon ?? "",
      kind: isKind(c.kind) ? c.kind : "expense",
      position: pgInt(c.position),
      parent_id: c.parent_id ?? null,
    }));
    // Tree order: every category after its parent. A parent that isn't there (or a loop)
    // makes the category a top-level one, as the finance page shows it anyway.
    const tree = categoryTree(list);
    for (const c of tree.ordered) {
      const parentId = tree.parentOf(c.id)?.id ?? null;
      if (c.parent_id && parentId !== c.parent_id) {
        ctx.skip("familyPlanner", "finance_categories", `${familyId}/${c.id} → ${c.parent_id}`, "its parent doesn't exist: imported as a top-level category");
      }
      db.insert(finCategories)
        .values({ familyId, id: c.id, name: c.name, color: c.color, icon: c.icon, kind: c.kind, position: c.position, parentId })
        .run();
    }
    categories.set(familyId, new Set(list.map((c) => c.id)));
  }

  const accounts = new Map<string, Set<string>>();
  for (const [familyId, rows] of byFamily(ctx, "finance_accounts", fpRows(src, "finance_accounts"), (r) => r.id ?? "")) {
    for (const a of rows) {
      db.insert(finAccounts)
        .values({
          familyId,
          id: a.id!,
          name: a.name ?? "",
          color: a.color ?? "#64748b",
          icon: a.icon ?? "",
          openingCents: pgInt(a.opening_cents),
          position: pgInt(a.position),
        })
        .run();
    }
    accounts.set(familyId, new Set(rows.map((a) => a.id!)));
  }

  for (const [familyId, all] of byFamily(ctx, "transactions", fpRows(src, "transactions"), (r) => r.id ?? "")) {
    const rows = all.filter((t) => {
      if (pgDay(t.day)) return true;
      ctx.skip("familyPlanner", "transactions", `${familyId}/${t.id}`, "no valid day");
      return false;
    });
    const ids = new Set(rows.map((t) => t.id!));
    const cats = categories.get(familyId) ?? new Set();
    const accs = accounts.get(familyId) ?? new Set();
    const ref = (t: PgRow, column: string, value: string | null, known: Set<string>) => {
      if (!value || known.has(value)) return value ?? null;
      ctx.skip("familyPlanner", "transactions", `${familyId}/${t.id} ${column} ${value}`, `the ${column} doesn't exist: cleared`);
      return null;
    };
    // Bookings before their parts (a stable sort: otherwise the dump's order, which is the
    // order within a day for transactions created at the same time).
    const ordered = [...rows].sort((a, b) => Number(!!a.split_of) - Number(!!b.split_of));
    for (const t of ordered) {
      db.insert(finTransactions)
        .values({
          familyId,
          id: t.id!,
          day: pgDay(t.day)!,
          amountCents: pgInt(t.amount_cents),
          payee: t.payee ?? "",
          description: t.description ?? "",
          categoryId: ref(t, "category", t.category_id, cats),
          note: t.note ?? "",
          importHash: t.import_hash || null,
          accountId: ref(t, "account", t.account_id, accs),
          transferId: t.transfer_id || null,
          splitOf: t.split_of === t.id ? null : ref(t, "booking", t.split_of, ids),
          createdAt: pgDate(t.created_at) ?? ctx.now,
        })
        .run();
    }
  }
}
