import type { Db } from "@/lib/db";
import { calEntryTypes } from "@/lib/db/schema";
import type { Lang } from "./ics";
import { newFamilyTypes } from "./vacation";

type Tx = Pick<Db, "insert">;

/** A new family's calendar: family-planner's preset types (Holiday, Vacation, Sick), named in
 *  `lang`, for `year`. Runs inside the caller's transaction. */
export function insertPresetTypes(tx: Tx, familyId: string, lang: Lang, year: number): void {
  const types = newFamilyTypes(undefined, lang).map((t, i) => ({
    familyId,
    year,
    id: t.id,
    name: t.name,
    color: t.color,
    role: t.role,
    position: i,
  }));
  tx.insert(calEntryTypes).values(types).run();
}
