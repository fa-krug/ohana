// Calendar → Meals (phase 7): the days on which the whole family is away from home, i.e. that
// have an entry of a calendar type marked "away" (Settings → Calendar). The meal plan gives
// them no meal and shows them as away.

import { and, asc, eq, gte, lte } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { calEntries, calEntryTypes } from "@/lib/db/schema";

/** day -> names of its "away" types, for the days from `from` to `to` (inclusive). */
export function awayDays(db: Db, familyId: string, from: string, to: string): Map<string, string[]> {
  const rows = db
    .select({ day: calEntries.day, name: calEntryTypes.name })
    .from(calEntries)
    .innerJoin(
      calEntryTypes,
      and(
        eq(calEntryTypes.familyId, calEntries.familyId),
        eq(calEntryTypes.year, calEntries.year),
        eq(calEntryTypes.id, calEntries.typeId),
      ),
    )
    .where(
      and(
        eq(calEntries.familyId, familyId),
        eq(calEntryTypes.away, true),
        gte(calEntries.day, from),
        lte(calEntries.day, to),
      ),
    )
    .orderBy(asc(calEntries.day), asc(calEntryTypes.position))
    .all();
  const out = new Map<string, string[]>();
  for (const r of rows) out.set(r.day, [...(out.get(r.day) ?? []), r.name]);
  return out;
}
