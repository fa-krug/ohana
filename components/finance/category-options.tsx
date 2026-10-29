"use client";

import { SelectItem } from "@/components/ui/select";
import type { Category } from "./api";
import { useFinance } from "./context";

/** Indentation per level, up to this many levels (deeper ones line up with the last). */
const MAX_INDENT = 6;

/** The categories as select items in tree order, subcategories indented under their parent;
 *  `fits` leaves out the ones it rejects. The trigger shows just the icon and name. */
export function CategoryOptions({ fits }: { fits?: (c: Category) => boolean }) {
  const finance = useFinance();
  return finance.categoryTree.ordered
    .filter((n) => !fits || fits(n.category))
    .map(({ category: c, depth }) => (
      <SelectItem
        key={c.id}
        value={c.id}
        style={{ paddingLeft: `${0.5 + Math.min(depth, MAX_INDENT) * 0.875}rem` }}
        title={depth ? finance.categoryTree.path(c.id) : undefined}
      >
        {c.icon} {c.name}
      </SelectItem>
    ));
}
