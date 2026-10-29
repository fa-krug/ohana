// Finance categories form a tree: a category may have a parent, at any depth (Food > Groceries
// > Bakery). Transactions can sit on any level; a category's totals include its subcategories.
// A subcategory has the kind (income / expense) of its top-level category.

import type { CategoryRow } from "./store";

/** Between the names of a category's path: "Food > Groceries". */
export const PATH_SEPARATOR = " > ";

export interface CategoryTree {
  /** Every category after its parent, siblings by position (depth first). */
  ordered: CategoryRow[];
  byId: Map<string, CategoryRow>;
  parentOf(id: string): CategoryRow | undefined;
  children(id: string | null): CategoryRow[];
  /** 1 for a top-level category. */
  depth(id: string): number;
  /** The category and its ancestors, top level first. */
  lineage(id: string): CategoryRow[];
  /** "Food > Groceries". */
  path(id: string): string;
  /** The category's id and those of all its descendants. */
  subtree(id: string): Set<string>;
  /** The category's ancestor at `level` (1 = top level), or itself if it isn't that deep. */
  atLevel(id: string, level: number): CategoryRow;
  /** Where the category is in `ordered`. */
  index(id: string): number;
}

/** The tree of the categories. A parent that doesn't exist (or a loop) counts as top level. */
export function categoryTree(categories: CategoryRow[]): CategoryTree {
  const byId = new Map(categories.map((c) => [c.id, c]));
  const sorted = [...categories].sort((a, b) =>
    a.position - b.position || a.name.localeCompare(b.name)
  );
  const kids = new Map<string | null, CategoryRow[]>();
  for (const c of sorted) {
    const p = c.parent_id && byId.has(c.parent_id) ? c.parent_id : null;
    kids.set(p, [...(kids.get(p) ?? []), c]);
  }
  const ordered: CategoryRow[] = [];
  const parent = new Map<string, string | null>();
  const depths = new Map<string, number>();
  const visit = (c: CategoryRow, p: string | null, d: number) => {
    if (depths.has(c.id)) return;
    depths.set(c.id, d);
    parent.set(c.id, p);
    ordered.push(c);
    for (const k of kids.get(c.id) ?? []) visit(k, c.id, d + 1);
  };
  for (const c of kids.get(null) ?? []) visit(c, null, 1);
  for (const c of sorted) visit(c, null, 1); // in a loop: the first one becomes top level
  const indexes = new Map(ordered.map((c, i) => [c.id, i]));

  const lineage = (id: string) => {
    const out: CategoryRow[] = [];
    for (let c = byId.get(id); c; c = byId.get(parent.get(c.id) ?? "")) out.unshift(c);
    return out;
  };
  const children = (id: string | null) => ordered.filter((c) => (parent.get(c.id) ?? null) === id);
  return {
    ordered,
    byId,
    parentOf: (id) => byId.get(parent.get(id) ?? ""),
    children,
    depth: (id) => depths.get(id) ?? 1,
    lineage,
    path: (id) => lineage(id).map((c) => c.name).join(PATH_SEPARATOR),
    subtree(id) {
      const out = new Set<string>([id]);
      // `ordered` has every descendant after its ancestor.
      for (const c of ordered) {
        const p = parent.get(c.id);
        if (p && out.has(p)) out.add(c.id);
      }
      return out;
    },
    atLevel(id, level) {
      const line = lineage(id);
      return line[Math.min(Math.max(1, level), line.length) - 1];
    },
    index: (id) => indexes.get(id) ?? Infinity,
  };
}
