// The number on the app's icon: the account's open chores that are due by now, in every family
// it's a member of but those the device muted. Due: a chore's day has come and its time has
// passed (its time, else when its part of the day starts, the family's day parts), so the
// morning's chores count from the morning on, the evening's from the evening; single chores left
// open from before (overdue) always count. "Its" chores: assigned to the account, or one it
// subscribed to (it's told when they're due).
// Sent with every push (lib/push/deliver.ts) and asked for by the app (GET /api/v1/me/badge),
// each time with the moments it changes until the end of tomorrow (`steps`) and the number from
// the next midnight (`tomorrow`, for older apps): the app has the system switch to them.
// Times are wall clock ("YYYY-MM-DDTHH:MM"): the family's chore times, read on the device's clock.

import { and, eq, inArray, or } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { choreCompletions, choreSubscribers, chores, familyMembers } from "@/lib/db/schema";
import { moduleEnabled } from "@/lib/server-info";
import { addDays } from "@/lib/calendar/dates";
import { type ChoreRow, choreDays, isOccurrence } from "./chores";
import { type DayParts, type Part, getDayParts } from "./day-parts";

/** At most this many changes are sent (a local notification each, of the 64 the system keeps). */
export const MAX_BADGE_STEPS = 16;

/** A wall-clock moment: the day ("YYYY-MM-DD") and the time ("HH:MM"). */
export interface BadgeMoment {
  day: string;
  time: string;
}

export interface BadgeStep {
  /** From this wall-clock moment on ("YYYY-MM-DDTHH:MM"). */
  at: string;
  count: number;
}

export interface ChoreBadges {
  count: number;
  /** The number from the next midnight on, should nothing change until then. */
  tomorrow: { day: string; count: number };
  /** Each moment from now to the end of tomorrow the number changes at, should nothing else. */
  steps: BadgeStep[];
}

/** The server's wall clock at `now`. */
export function localMoment(now: Date): BadgeMoment {
  const p = (n: number) => String(n).padStart(2, "0");
  return {
    day: `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`,
    time: `${p(now.getHours())}:${p(now.getMinutes())}`,
  };
}

export function choreBadge(db: Db, userId: string, at: BadgeMoment, mutedFamilyIds: string[] = []): number {
  return new Badge(db, ownChores(db, userId, mutedFamilyIds), at.day).countAt(stamp(at.day, at.time));
}

/** Now's number, tomorrow's and the changes until the end of tomorrow. */
export function choreBadges(db: Db, userId: string, at: BadgeMoment, mutedFamilyIds: string[] = []): ChoreBadges {
  const badge = new Badge(db, ownChores(db, userId, mutedFamilyIds), at.day);
  const now = stamp(at.day, at.time);
  const tomorrow = addDays(at.day, 1);
  const midnight = stamp(tomorrow, "00:00");
  const count = badge.countAt(now);
  const steps: BadgeStep[] = [];
  let last = count;
  for (const moment of badge.moments().filter((m) => m > now)) {
    if (steps.length >= MAX_BADGE_STEPS) break;
    const n = badge.countAt(moment);
    if (n !== last) steps.push({ at: moment, count: n });
    last = n;
  }
  return { count, tomorrow: { day: tomorrow, count: badge.countAt(midnight) }, steps };
}

function stamp(day: string, time: string): string {
  return `${day}T${time}`;
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

/** The account's chores from `today` to tomorrow, counted at any moment of those two days. */
class Badge {
  private readonly parts = new Map<string, DayParts>();
  /** The repeating chores' occurrences ticked off on the two days ("id|day"). */
  private readonly done: Set<string>;
  private readonly days: string[];

  constructor(
    private readonly db: Db,
    private readonly rows: ChoreRow[],
    today: string,
  ) {
    this.days = [today, addDays(today, 1)];
    const repeating = rows.filter((r) => r.rrule).map((r) => r.id);
    this.done = new Set(
      repeating.length
        ? db
            .select({ choreId: choreCompletions.choreId, day: choreCompletions.day })
            .from(choreCompletions)
            .where(and(inArray(choreCompletions.choreId, repeating), inArray(choreCompletions.day, this.days)))
            .all()
            .map((c) => `${c.choreId}|${c.day}`)
        : [],
    );
  }

  /** When the chore is due on `day` (wall clock): its time, else when its part starts. */
  private dueAt(row: ChoreRow, day: string): string {
    if (!this.parts.has(row.familyId)) this.parts.set(row.familyId, getDayParts(this.db, row.familyId));
    const parts = this.parts.get(row.familyId)!;
    return stamp(day, row.time ?? parts[row.part as Part] ?? parts.day);
  }

  /** Open and due at `moment` (on one of the two days): single chores due by then, and the
   *  day's occurrences of repeating ones due by then and not ticked off. */
  countAt(moment: string): number {
    const day = moment.slice(0, 10);
    let n = 0;
    for (const r of this.rows) {
      if (!r.rrule) {
        if (!r.doneAt && this.dueAt(r, r.day) <= moment) n += 1;
      } else if (isOccurrence(r, day) && !this.done.has(`${r.id}|${day}`) && this.dueAt(r, day) <= moment) n += 1;
    }
    return n;
  }

  /** The moments the number may change at on the two days, in order: the open chores' due
   *  moments and the next midnight (repeating ones of the day before drop out). */
  moments(): string[] {
    const out = new Set<string>([stamp(this.days[1], "00:00")]);
    for (const r of this.rows) {
      if (!r.rrule && r.doneAt) continue;
      for (const day of choreDays(r, this.days[0], this.days[1])) {
        if (!this.done.has(`${r.id}|${day}`)) out.add(this.dueAt(r, day));
      }
    }
    return [...out].sort();
  }
}
