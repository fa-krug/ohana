// When the family's parts of the day start (`chore_day_parts`, editors change them; no row: the
// defaults). A chore's time decides its part: before `day` the morning (also before `morning`),
// before `evening` the day, else the evening. A chore without a time is due, and notified, when
// its part starts. Changing them moves the family's chores with a time into their new part.

import { and, eq, isNotNull } from "drizzle-orm";
import { z } from "zod";
import type { Db } from "@/lib/db";
import { choreDayParts, chores } from "@/lib/db/schema";

export const PARTS = ["morning", "day", "evening"] as const;
export type Part = (typeof PARTS)[number];

/** When each part of the day starts ("HH:MM"). */
export type DayParts = Record<Part, string>;

export const DEFAULT_DAY_PARTS: DayParts = { morning: "07:00", day: "12:00", evening: "18:00" };

const TIME = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, "must be HH:MM");

const schema = z
  .object({ morning: TIME, day: TIME, evening: TIME })
  .refine((p) => p.morning < p.day && p.day < p.evening, "The morning must start before the day, the day before the evening");

/** The part of the day a time falls in. */
export function partOfTime(time: string, parts: DayParts = DEFAULT_DAY_PARTS): Part {
  return time < parts.day ? "morning" : time < parts.evening ? "day" : "evening";
}

export function getDayParts(db: Db, familyId: string): DayParts {
  const row = db.select().from(choreDayParts).where(eq(choreDayParts.familyId, familyId)).get();
  return row ? { morning: row.morning, day: row.day, evening: row.evening } : { ...DEFAULT_DAY_PARTS };
}

/** Changes the ones the body has (400 unless times, the three in order); the chores with a time
 *  move into their part. */
export function setDayParts(db: Db, familyId: string, body: Record<string, unknown>, now: Date): DayParts {
  const merged: Record<string, unknown> = { ...getDayParts(db, familyId) };
  for (const p of PARTS) if (p in body) merged[p] = body[p];
  const parts: DayParts = schema.parse(merged);
  db.transaction((tx) => {
    tx.insert(choreDayParts)
      .values({ familyId, ...parts, updatedAt: now })
      .onConflictDoUpdate({ target: choreDayParts.familyId, set: { ...parts, updatedAt: now } })
      .run();
    const timed = tx
      .select({ id: chores.id, time: chores.time, part: chores.part })
      .from(chores)
      .where(and(eq(chores.familyId, familyId), isNotNull(chores.time)))
      .all();
    for (const c of timed) {
      const part = partOfTime(c.time!, parts);
      if (part !== c.part) tx.update(chores).set({ part }).where(eq(chores.id, c.id)).run();
    }
  });
  return parts;
}
