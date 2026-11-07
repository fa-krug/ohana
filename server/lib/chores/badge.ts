// The number on the app's icon: the account's open chores due today, plus the single chores
// left open from before (overdue), in every family it's a member of but those the device muted.
// "Its" chores: assigned to the account, or one it subscribed to (it's told when they're due).
// Sent with every push (lib/push/deliver.ts) and asked for by the app (GET /api/v1/me/badge),
// each time with tomorrow's number too: the app has the system switch to it at midnight.

import { and, eq, inArray, or } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { choreCompletions, choreSubscribers, chores, familyMembers } from "@/lib/db/schema";
import { moduleEnabled } from "@/lib/server-info";
import { addDays } from "@/lib/calendar/dates";
import { type ChoreRow, isOccurrence } from "./chores";

export interface ChoreBadges {
  count: number;
  /** The number from the next midnight on, should nothing change until then. */
  tomorrow: { day: string; count: number };
}

export function choreBadge(db: Db, userId: string, today: string, mutedFamilyIds: string[] = []): number {
  return countOn(db, ownChores(db, userId, mutedFamilyIds), today);
}

/** Today's number and tomorrow's. */
export function choreBadges(db: Db, userId: string, today: string, mutedFamilyIds: string[] = []): ChoreBadges {
  const rows = ownChores(db, userId, mutedFamilyIds);
  const tomorrow = addDays(today, 1);
  return { count: countOn(db, rows, today), tomorrow: { day: tomorrow, count: countOn(db, rows, tomorrow) } };
}

/** The account's chores: assigned to it or subscribed, in its families but the muted ones. */
function ownChores(db: Db, userId: string, mutedFamilyIds: string[]): ChoreRow[] {
  if (!moduleEnabled("chores")) return [];
  const familyIds = db
    .select({ familyId: familyMembers.familyId })
    .from(familyMembers)
    .where(eq(familyMembers.userId, userId))
    .all()
    .map((m) => m.familyId)
    .filter((id) => !mutedFamilyIds.includes(id));
  if (!familyIds.length) return [];
  const subscribed = db
    .select({ choreId: choreSubscribers.choreId })
    .from(choreSubscribers)
    .where(eq(choreSubscribers.userId, userId))
    .all()
    .map((s) => s.choreId);
  return db
    .select()
    .from(chores)
    .where(
      and(
        inArray(chores.familyId, familyIds),
        subscribed.length
          ? or(eq(chores.assigneeUserId, userId), inArray(chores.id, subscribed))
          : eq(chores.assigneeUserId, userId),
      ),
    )
    .all();
}

/** Open on `today`: due that day (a repeating one's occurrence not ticked off), or a single
 *  one left open from before. */
function countOn(db: Db, rows: ChoreRow[], today: string): number {
  const repeatingToday = rows.filter((r) => isOccurrence(r, today)).map((r) => r.id);
  const doneToday = new Set(
    repeatingToday.length
      ? db
          .select({ choreId: choreCompletions.choreId })
          .from(choreCompletions)
          .where(and(inArray(choreCompletions.choreId, repeatingToday), eq(choreCompletions.day, today)))
          .all()
          .map((c) => c.choreId)
      : [],
  );
  const singles = rows.filter((r) => !r.rrule && !r.doneAt && r.day <= today).length;
  return singles + repeatingToday.filter((id) => !doneToday.has(id)).length;
}
