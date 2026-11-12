// Coverage gaps: weekdays with a "needs cover" entry but neither a "covers" nor a "day off" one
// (the overview's next gap, the daily coverage notification).

import { isWeekend } from "./dates";
import type { TypeRow } from "./store";

/** The gap days among `entries` (day -> type ids of that day's year), sorted. */
export function gapDays(types: TypeRow[], entries: Map<string, string[]>): string[] {
  const role = new Map(types.map((t) => [`${t.year}|${t.id}`, t.role]));
  const out: string[] = [];
  for (const [day, ids] of entries) {
    if (isWeekend(day)) continue;
    const roles = ids.map((id) => role.get(`${day.slice(0, 4)}|${id}`));
    if (!roles.includes("needs_cover")) continue;
    if (roles.includes("covers") || roles.includes("day_off")) continue;
    out.push(day);
  }
  return out.sort();
}

/** Whether a "cover only" type's entry is left out of the overview on a day: a "covers" type
 *  that shows only where it covers (`cover_only`), on a day (`roles`: the roles of all its
 *  types) without a "needs cover" entry. The entry stays stored and counted; the app's
 *  `CalendarMath.isHidden` is the same rule (its cells and Apple Calendar sync). */
export function hiddenEntry(type: Pick<TypeRow, "role" | "cover_only">, roles: readonly (string | undefined)[]): boolean {
  return type.role === "covers" && (type.cover_only ?? false) && !roles.includes("needs_cover");
}
