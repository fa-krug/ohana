// Finance categories form a tree (any depth, e.g. Food > Groceries > Bakery). Transactions can
// sit on any level; a category's totals include its subcategories, and a subcategory has the
// kind (income / expense) of its top-level category.

import type { Category } from "./api";

export const PATH_SEPARATOR = " › ";

export interface CategoryNode {
  category: Category;
  /** 0 for a top-level category. */
  depth: number;
  children: CategoryNode[];
}

export interface CategoryTree {
  roots: CategoryNode[];
  /** Every category after its parent, siblings by position (depth first). */
  ordered: CategoryNode[];
  byId: Map<string, CategoryNode>;
  parentOf(id: string): Category | undefined;
  /** "Food › Groceries". */
  path(id: string): string;
  /** The category's id and those of all its descendants. */
  subtree(id: string): Set<string>;
}

/** The tree of the categories. A parent that doesn't exist (or a loop) counts as top level. */
export function buildCategoryTree(categories: Category[]): CategoryTree {
  const known = new Set(categories.map((c) => c.id));
  const sorted = [...categories].sort((a, b) =>
    a.position - b.position || a.name.localeCompare(b.name)
  );
  const kids = new Map<string | null, Category[]>();
  for (const c of sorted) {
    const p = c.parentId && known.has(c.parentId) ? c.parentId : null;
    kids.set(p, [...(kids.get(p) ?? []), c]);
  }
  const byId = new Map<string, CategoryNode>();
  const parents = new Map<string, string | null>();
  const ordered: CategoryNode[] = [];
  const visit = (c: Category, parent: string | null, depth: number): CategoryNode | null => {
    if (byId.has(c.id)) return null;
    const node: CategoryNode = { category: c, depth, children: [] };
    byId.set(c.id, node);
    parents.set(c.id, parent);
    ordered.push(node);
    for (const k of kids.get(c.id) ?? []) {
      const child = visit(k, c.id, depth + 1);
      if (child) node.children.push(child);
    }
    return node;
  };
  const roots: CategoryNode[] = [];
  // In a loop: the first one becomes top level.
  for (const c of [...(kids.get(null) ?? []), ...sorted]) {
    const node = visit(c, null, 0);
    if (node) roots.push(node);
  }

  const parentOf = (id: string) => byId.get(parents.get(id) ?? "")?.category;
  return {
    roots,
    ordered,
    byId,
    parentOf,
    path(id) {
      const names: string[] = [];
      for (let c = byId.get(id)?.category; c; c = parentOf(c.id)) names.unshift(c.name);
      return names.join(PATH_SEPARATOR);
    },
    subtree(id) {
      const out = new Set<string>();
      const add = (n: CategoryNode) => {
        out.add(n.category.id);
        n.children.forEach(add);
      };
      const node = byId.get(id);
      if (node) add(node);
      return out;
    },
  };
}
