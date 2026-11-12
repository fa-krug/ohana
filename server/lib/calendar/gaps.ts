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
