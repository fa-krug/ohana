import type { Db } from "@/lib/db";
import { calEntryTypes } from "@/lib/db/schema";
import type { Lang } from "@/lib/i18n/config";
import { newFamilyTypes } from "./vacation";

type Tx = Pick<Db, "insert">;

/** A new family's calendar: family-planner's preset types (Holiday, Vacation, Sick), named in
 *  `lang`, for `year`, all `memberUserId`'s (the creating editor; null: nobody's). Runs inside
 *  the caller's transaction, after that member was added. */
export function insertPresetTypes(tx: Tx, familyId: string, lang: Lang, year: number, memberUserId: string | null): void {
  const types = newFamilyTypes(undefined, lang).map((t, i) => ({
    familyId,
    year,
    id: t.id,
    name: t.name,
    memberUserId,
    role: t.role,
    icon: t.icon,
    position: i,
  }));
  tx.insert(calEntryTypes).values(types).run();
}
