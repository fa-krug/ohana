import type { Lang } from "@/lib/calendar/ics";
import { defaultCategories } from "./finance";
import { insertCategories } from "./store";

type Tx = Parameters<typeof insertCategories>[0];

/** A new family's finances: family-planner's default categories, named in `lang` (the
 *  currency stays the default, EUR). Runs inside the caller's transaction. */
export function insertDefaultCategories(tx: Tx, familyId: string, lang: Lang): void {
  insertCategories(tx, defaultCategories(familyId, lang));
}
