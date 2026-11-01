// What the family overview shows of the calendar: the next weekday that needs cover but has
// none, and what comes up in the next weeks.

import type { Db } from "@/lib/db";
import { addDays, consecutiveRuns } from "./dates";
import { gapDays } from "./gaps";
import { DrizzleCalendarStore } from "./store";

export interface CalendarSummary {
  /** The first uncovered weekday from today on (within `days`), or null. */
  nextGap: string | null;
  /** Runs of an entry type that end today or later, by start, at most `limit`. */
  upcoming: { name: string; color: string; from: string; to: string }[];
}

export async function calendarSummary(
  db: Db,
  familyId: string,
  today: string,
  { days = 60, limit = 4 }: { days?: number; limit?: number } = {},
): Promise<CalendarSummary> {
  const store = new DrizzleCalendarStore(db);
  const until = addDays(today, days);
  // Runs that started before today still show; look back a little to find their start.
  const [types, rows] = await Promise.all([
    store.listTypes(familyId),
    store.listEntries(familyId, addDays(today, -31), until),
  ]);
  const entries = new Map<string, string[]>();
  for (const r of rows) entries.set(r.day, [...(entries.get(r.day) ?? []), r.type_id]);

  const nextGap = gapDays(types, entries).find((d) => d >= today) ?? null;

  const upcoming: CalendarSummary["upcoming"] = [];
  for (const type of types) {
    const days = rows.filter((r) => r.type_id === type.id && r.day.startsWith(`${type.year}-`)).map((r) => r.day);
    for (const run of consecutiveRuns(days)) {
      const to = run[run.length - 1];
      if (to < today || run[0] > until) continue;
      upcoming.push({ name: type.name, color: type.color, from: run[0], to });
    }
  }
  upcoming.sort((a, b) => a.from.localeCompare(b.from) || a.name.localeCompare(b.name));
  return { nextGap, upcoming: upcoming.slice(0, limit) };
}
