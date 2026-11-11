// "A chore is due" (the worker, every WORKER_TICK_SECONDS): every chore with subscribers, each
// of its days due today or yesterday (server-local, like lib/notifications/daily.ts), once its
// due moment (its time, else when its part of the day starts, the family's day parts) has passed but not more than
// DUE_WINDOW_MS ago, while it isn't done and wasn't told before (`chore_notified`): a push to
// the subscribers' app devices only (no channels), in the family's language, with a link to the
// chore's day.

import { and, eq, inArray } from "drizzle-orm";
import { getAppUrl } from "@/lib/auth/config";
import { addDays } from "@/lib/calendar/dates";
import type { Db } from "@/lib/db";
import { choreNotified, choreSubscribers, chores } from "@/lib/db/schema";
import { notifyFamily } from "@/lib/notifications";
import { localDay } from "@/lib/notifications/daily";
import { familyLocale, translator } from "@/lib/notifications/locale";
import type { RelayClient } from "@/lib/push/relay";
import { moduleEnabled } from "@/lib/server-info";
import { type ChoreRow, choreDays, chorePeople, occurrenceDone } from "./chores";
import { DEFAULT_DAY_PARTS, type DayParts, type Part, getDayParts } from "./day-parts";

/** A day is told about until this long after its due moment (a worker that was down for longer
 *  doesn't tell about it late). */
export const DUE_WINDOW_MS = 3 * 60 * 60 * 1000;

/** The server-local moment a chore is due on `day`: its time, else when its part of the day
 *  starts. */
export function dueMoment(row: Pick<ChoreRow, "time" | "part">, day: string, parts: DayParts = DEFAULT_DAY_PARTS): Date {
  const [y, m, d] = day.split("-").map(Number);
  const [hh, mm] = (row.time ?? parts[row.part as Part] ?? parts.day).split(":").map(Number);
  return new Date(y, m - 1, d, hh, mm);
}

export interface ChoreNotice {
  choreId: string;
  day: string;
  userIds: string[];
}

/** Tells the subscribers about the chores that are due now; returns what it told about. */
export async function choreNotifications(
  db: Db,
  now: Date,
  opts: { push?: RelayClient } = {},
): Promise<ChoreNotice[]> {
  if (!moduleEnabled("chores")) return [];
  const today = localDay(now);
  const yesterday = addDays(today, -1);
  const subscribed = new Map<string, string[]>();
  for (const s of db.select().from(choreSubscribers).all()) {
    subscribed.set(s.choreId, [...(subscribed.get(s.choreId) ?? []), s.userId]);
  }
  if (!subscribed.size) return [];
  const rows = db.select().from(chores).where(inArray(chores.id, [...subscribed.keys()])).all();
  const told: ChoreNotice[] = [];
  const partsOf = new Map<string, DayParts>();
  for (const row of rows) {
    if (!row.rrule && row.doneAt) continue;
    for (const day of choreDays(row, yesterday, today)) {
      if (!partsOf.has(row.familyId)) partsOf.set(row.familyId, getDayParts(db, row.familyId));
      const due = dueMoment(row, day, partsOf.get(row.familyId));
      const late = now.getTime() - due.getTime();
      if (late < 0 || late > DUE_WINDOW_MS) continue;
      if (row.rrule && occurrenceDone(db, row.id, day)) continue;
      const notified = db
        .select({ day: choreNotified.day })
        .from(choreNotified)
        .where(and(eq(choreNotified.choreId, row.id), eq(choreNotified.day, day)))
        .get();
      if (notified) continue;
      const userIds = subscribed.get(row.id) ?? [];
      try {
        await notifyChore(db, row, day, userIds, opts);
      } catch (e) {
        console.error(`[chores] notification of chore ${row.id} failed:`, e);
      }
      // Once, sent or not: a device that fails now isn't asked again every minute.
      db.insert(choreNotified).values({ choreId: row.id, day, sentAt: now }).onConflictDoNothing().run();
      told.push({ choreId: row.id, day, userIds });
    }
  }
  return told;
}

async function notifyChore(db: Db, row: ChoreRow, day: string, userIds: string[], opts: { push?: RelayClient }) {
  const t = translator(familyLocale(db, row.familyId));
  const assigneeId = row.assigneeUserId ?? row.assigneePersonId;
  const assignee = assigneeId ? chorePeople(db, row.familyId).find((p) => p.id === assigneeId) : undefined;
  // "for Mia", unless Mia is the only one told.
  const forWhom = assignee && !(userIds.length === 1 && userIds[0] === assignee.id) ? assignee.name : null;
  const when = row.time ? t("notifications.chores.dueAt", { time: row.time }) : t("notifications.chores.dueNow");
  await notifyFamily(
    db,
    row.familyId,
    {
      title: row.title,
      body: forWhom ? `${when} · ${t("notifications.chores.for", { name: forWhom })}` : when,
      url: `${getAppUrl()}/f/${row.familyId}/chores/${row.id}?day=${day}`,
      collapseKey: `chore:${row.id}:${day}`,
    },
    { channelIds: [], app: { userIds }, event: "chore_due", push: opts.push },
  );
}
