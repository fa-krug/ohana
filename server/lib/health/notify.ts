// "A check-up or vaccination is due" (the worker, every WORKER_TICK_SECONDS, from NOTIFY_HOUR):
// pushed to the family's editors' app devices (no channels: it's health data), in the family's
// language, with a link to the member's page. Once each (`health_notified`):
//
// - open: a window opened (status due) in the last OPEN_WITHIN_DAYS days. Windows that opened
//   earlier aren't announced late (most of them before anyone used Ohana).
// - closing: a check-up's window closes in CLOSING_DAYS days or less without a record; only for
//   windows longer than SHORT_WINDOW_DAYS (a short one's opening message already says until when).

import { and, eq } from "drizzle-orm";
import { getAppUrl } from "@/lib/auth/config";
import { addDays, diffDays } from "@/lib/calendar/dates";
import type { Db } from "@/lib/db";
import { families, familyMembers, healthNotified, healthRecords } from "@/lib/db/schema";
import { notifyFamily } from "@/lib/notifications";
import { localDay } from "@/lib/notifications/daily";
import { familyLocale, translator } from "@/lib/notifications/locale";
import type { RelayClient } from "@/lib/push/relay";
import { moduleEnabled } from "@/lib/server-info";
import { healthMembers, toRecord } from "./health";
import { type ItemState, personHealth } from "./status";

export const OPEN_WITHIN_DAYS = 14;
export const CLOSING_DAYS = 28;
export const SHORT_WINDOW_DAYS = 42;

export interface HealthNotice {
  familyId: string;
  memberId: string;
  code: string;
  kind: "open" | "closing";
  userIds: string[];
}

/** The notices due for one item on `today` (keys of `health_notified`). */
export function noticesFor(item: ItemState, today: string): { kind: "open" | "closing"; key: string }[] {
  if (item.status !== "due" || !item.from) return [];
  const out: { kind: "open" | "closing"; key: string }[] = [];
  if (item.from <= today && item.from >= addDays(today, -OPEN_WITHIN_DAYS)) {
    out.push({ kind: "open", key: `${item.code}:${item.from}:open` });
  }
  if (
    item.kind === "checkup" &&
    item.until &&
    item.until >= today &&
    diffDays(today, item.until) <= CLOSING_DAYS &&
    diffDays(item.from, item.until) > SHORT_WINDOW_DAYS &&
    !out.length
  ) {
    out.push({ kind: "closing", key: `${item.code}:${item.from}:closing` });
  }
  return out;
}

function dayFormat(locale: string) {
  const f = new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", {
    day: "numeric",
    month: "short",
    year: "numeric",
    timeZone: "UTC",
  });
  return (d: string) => f.format(new Date(`${d}T00:00:00Z`));
}

/** Pushes the reminders that are due now to the editors; returns what it told about. */
export async function healthNotifications(
  db: Db,
  now: Date,
  opts: { push?: RelayClient; hour?: number } = {},
): Promise<HealthNotice[]> {
  if (!moduleEnabled("health")) return [];
  const hour = opts.hour ?? Number(process.env.NOTIFY_HOUR ?? 7);
  if (now.getHours() < hour) return [];
  const today = localDay(now);
  const told: HealthNotice[] = [];
  for (const { id: familyId } of db.select({ id: families.id }).from(families).all()) {
    const editors = db
      .select({ id: familyMembers.userId })
      .from(familyMembers)
      .where(and(eq(familyMembers.familyId, familyId), eq(familyMembers.role, "editor")))
      .all()
      .map((r) => r.id);
    if (!editors.length) continue;
    const members = healthMembers(db, familyId, null).filter((m) => m.birthday);
    if (!members.length) continue;
    const records = db.select().from(healthRecords).where(eq(healthRecords.familyId, familyId)).all();
    const locale = familyLocale(db, familyId);
    for (const m of members) {
      const mine = records.filter((r) => (r.memberUserId ?? r.memberPersonId) === m.id).map(toRecord);
      for (const item of personHealth(m.birthday, today, mine, locale).items) {
        for (const notice of noticesFor(item, today)) {
          const sent = db
            .select({ key: healthNotified.key })
            .from(healthNotified)
            .where(
              and(eq(healthNotified.familyId, familyId), eq(healthNotified.memberId, m.id), eq(healthNotified.key, notice.key)),
            )
            .get();
          if (sent) continue;
          try {
            await notifyItem(db, familyId, m, item, notice.kind, editors, { ...opts, now, locale });
          } catch (e) {
            console.error(`[health] notification of ${item.code} for ${m.id} failed:`, e);
          }
          // Once, sent or not.
          db.insert(healthNotified).values({ familyId, memberId: m.id, key: notice.key, sentAt: now }).onConflictDoNothing().run();
          told.push({ familyId, memberId: m.id, code: item.code, kind: notice.kind, userIds: editors });
        }
      }
    }
  }
  return told;
}

async function notifyItem(
  db: Db,
  familyId: string,
  member: { id: string; name: string },
  item: ItemState,
  kind: "open" | "closing",
  userIds: string[],
  opts: { push?: RelayClient; now: Date; locale: "en" | "de" },
) {
  const t = translator(opts.locale);
  const day = dayFormat(opts.locale);
  const body =
    kind === "closing"
      ? t("notifications.health.closing", { date: day(item.until!) })
      : item.until
        ? t("notifications.health.dueUntil", { date: day(item.until) })
        : t("notifications.health.due");
  await notifyFamily(
    db,
    familyId,
    {
      title: t("notifications.health.title", { item: item.title, name: member.name }),
      body,
      url: `${getAppUrl()}/f/${familyId}/health/${member.id}`,
      collapseKey: `health:${member.id}:${item.code}`,
    },
    { channelIds: [], app: { userIds }, event: "health_due", push: opts.push, now: opts.now },
  );
}
