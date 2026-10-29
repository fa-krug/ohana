// The pure part of the shopping-list links (shared with the finance page in the browser).

import { diffDays } from "@/lib/calendar/dates";

/** How far from the shopping day a purchase still counts (days, both ways). */
export const SHOPPING_SLACK_DAYS = 1;

/** For the finance page: the groceries categories and the family's shopping days, so a
 *  groceries transaction can link to the list of its shopping trip. */
export interface ShoppingLinks {
  categoryIds: string[];
  lists: { date: string; id: string }[];
}

/** The shopping list a transaction belongs to: one in a groceries category whose day is
 *  within ± SHOPPING_SLACK_DAYS of a shopping day (the nearest; on a tie the earlier list). */
export function listForTransaction(
  links: ShoppingLinks,
  t: { date: string; categoryId: string | null },
): { date: string; id: string } | null {
  if (!t.categoryId || !links.categoryIds.includes(t.categoryId)) return null;
  let best: { date: string; id: string } | null = null;
  let bestDist = Infinity;
  for (const l of links.lists) {
    const d = Math.abs(diffDays(l.date, t.date));
    if (d <= SHOPPING_SLACK_DAYS && d < bestDist) {
      best = l;
      bestDist = d;
    }
  }
  return best;
}
