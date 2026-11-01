// The week ahead (phase 11): the next two weeks of a family, what's coming and what doesn't
// work out (./checks.ts), for the app's page (GET /digest), the overview's card, the assistant
// (check_schedule) and the weekly notification (`weekly_digest`).
//
// The notification: every DIGEST_WEEKDAY (0 = Sunday) from DIGEST_HOUR (18, server time) the
// worker sends each family one digest, once a day (state.lastSent), nothing when the two weeks
// have no events, no away days and no birthdays. The family's channels get every conflict and
// warning; each account member's app devices get the issues about them, about the people
// without an account (the children) and the unassigned ones, info-level ones too.

import { and, asc, eq, lt } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { digestDismissals, families, familyMembers } from "@/lib/db/schema";
import { getAppUrl } from "@/lib/auth/config";
import { addDays, consecutiveRuns, diffDays } from "@/lib/calendar/dates";
import { listOccurrences } from "@/lib/calendar/events";
import { type BirthdayDay, birthdaysIn } from "@/lib/families/birthdays";
import { familyNames } from "@/lib/families/people";
import { awayDays } from "@/lib/meals/meal-plan/away";
import { type NotifyResult, type Sender, notifyFamily } from "@/lib/notifications";
import { localDay } from "@/lib/notifications/daily";
import { type TFn, familyLocale, translator } from "@/lib/notifications/locale";
import { getPref, readState, writeState } from "@/lib/notifications/prefs";
import type { RelayClient } from "@/lib/push/relay";
import { attributor, isChild } from "./attribution";
import { type Issue, SEVERITY_RANK, checkSchedule } from "./checks";
import { DIGEST_DAYS, type PlaceLookup, cachedPlaces, geocodingEnabled, homeOf, refreshPlaces } from "./geo";

export interface DigestPerson {
  id: string;
  name: string;
  account: boolean;
  /** Under 14 on the first day. */
  child: boolean;
  /** Occurrences of theirs in the range. */
  events: number;
}

export interface AwayRun {
  from: string;
  to: string;
  names: string[];
}

export interface Digest {
  from: string;
  to: string;
  /** Whether event locations are geocoded (DIGEST_GEOCODE). */
  geocoding: boolean;
  people: DigestPerson[];
  /** By date, then severity; dismissed ones included (`dismissed: true`). */
  issues: Issue[];
  away: AwayRun[];
  birthdays: BirthdayDay[];
}

/** Lines of issues in a notification at most. */
export const MAX_LINES = 10;

// ---- dismissals ----

/** The keys the family dismissed. */
export function dismissedKeys(db: Db, familyId: string): Set<string> {
  return new Set(
    db
      .select({ key: digestDismissals.key })
      .from(digestDismissals)
      .where(eq(digestDismissals.familyId, familyId))
      .all()
      .map((r) => r.key),
  );
}

/** Hides an issue for good ("Looks fine"); `day` is the last day it concerns. */
export function dismissIssue(db: Db, familyId: string, key: string, day: string, userId: string | null, now: Date): void {
  db.insert(digestDismissals)
    .values({ familyId, key, day, createdById: userId, createdAt: now })
    .onConflictDoUpdate({ target: [digestDismissals.familyId, digestDismissals.key], set: { day } })
    .run();
}

/** Shows a dismissed issue again. */
export function restoreIssue(db: Db, familyId: string, key: string): void {
  db.delete(digestDismissals)
    .where(and(eq(digestDismissals.familyId, familyId), eq(digestDismissals.key, key)))
    .run();
}

/** Removes the dismissals whose last day passed (cleanup). */
export function pruneDismissals(db: Db, now: Date): number {
  return db.delete(digestDismissals).where(lt(digestDismissals.day, localDay(now))).run().changes;
}

/** The last day an issue concerns. */
export function lastDayOf(issue: Issue): string {
  return issue.events.reduce((d, e) => (e.endDate > d ? e.endDate : d), issue.date);
}

// ---- building ----

interface Gathered {
  digest: Digest;
  /** Occurrences in the range. */
  eventCount: number;
}

function gather(db: Db, familyId: string, from: string, to: string): Gathered {
  const events = listOccurrences(db, familyId, { from, to });
  const people = familyNames(db, familyId);
  const away = awayDays(db, familyId, from, to);
  const geocoding = geocodingEnabled();
  const issues = checkSchedule({
    from,
    to,
    events,
    people,
    away,
    home: homeOf(db, familyId),
    places: geocoding ? cachedPlaces(db, familyId, events.map((e) => e.location)) : new Map(),
  });
  const dismissed = dismissedKeys(db, familyId);
  for (const issue of issues) issue.dismissed = dismissed.has(issue.key);

  const attribute = attributor(people);
  const counts = new Map<string, number>();
  for (const e of events) for (const id of attribute(e.person)) counts.set(id, (counts.get(id) ?? 0) + 1);
  const runs = consecutiveRuns([...away.keys()].sort()).map((run) => ({
    from: run[0],
    to: run[run.length - 1],
    names: [...new Set(run.flatMap((d) => away.get(d) ?? []))],
  }));
  return {
    digest: {
      from,
      to,
      geocoding,
      people: people.map((p) => ({
        id: p.id,
        name: p.name,
        account: p.account,
        child: isChild(p, from),
        events: counts.get(p.id) ?? 0,
      })),
      issues,
      away: runs,
      birthdays: birthdaysIn(people, from, to),
    },
    eventCount: events.length,
  };
}

/** The week ahead from `today` (14 days). Reads the geocoding cache only. */
export function buildDigest(db: Db, familyId: string, today: string): Digest {
  return gather(db, familyId, today, addDays(today, DIGEST_DAYS - 1)).digest;
}

/** The issues of any range (the assistant's check_schedule). */
export function scheduleIssues(db: Db, familyId: string, from: string, to: string): Issue[] {
  return gather(db, familyId, from, to).digest.issues;
}

/** The overview's card: open conflicts and warnings, and the three most pressing issues. */
export function weekAhead(db: Db, familyId: string, today: string): { conflicts: number; warnings: number; top: Issue[] } {
  const open = buildDigest(db, familyId, today).issues.filter((i) => !i.dismissed);
  const top = [...open]
    .sort((a, b) => SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity] || a.date.localeCompare(b.date))
    .slice(0, 3);
  return {
    conflicts: open.filter((i) => i.severity === "conflict").length,
    warnings: open.filter((i) => i.severity === "warning").length,
    top,
  };
}

// ---- the notification's text ----

function dayFormat(locale: string) {
  const f = new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", {
    weekday: "short",
    day: "numeric",
    month: "short",
    timeZone: "UTC",
  });
  return (d: string) => f.format(new Date(`${d}T00:00:00Z`));
}

function names(list: string[], t: TFn): string {
  if (list.length <= 1) return list[0] ?? "";
  return `${list.slice(0, -1).join(", ")} ${t("notifications.digest.and")} ${list[list.length - 1]}`;
}

/** One issue as a sentence in the family's language. */
export function issueSentence(issue: Issue, t: TFn, locale: string): string {
  const num = new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", { maximumFractionDigits: 1 });
  const vars: Record<string, string | number> = {
    who: names(
      issue.people.map((p) => p.name),
      t,
    ),
    a: issue.events[0]?.title ?? "",
    b: issue.events[1]?.title ?? "",
  };
  for (const [k, v] of Object.entries(issue.data)) {
    if (typeof v === "number") vars[k] = num.format(v);
    else if (typeof v === "string") vars[k] = v;
  }
  let key: string = issue.kind;
  if (issue.kind === "tight_transfer" && issue.data.travelMinutes === null) key = "tight_transfer_nearby";
  if (issue.kind === "during_trip") {
    vars.trip = vars.a;
    vars.a = vars.b;
  }
  return t(`notifications.digest.issue.${key}`, vars);
}

/** The digest as a notification: a summary line, up to MAX_LINES issues, "and N more". */
export function digestMessage(
  issues: Issue[],
  stats: { events: number; birthdays: number; awayDays: number },
  t: TFn,
  locale: string,
  familyId: string,
): { title: string; body: string; url: string; collapseKey: string } {
  const fmt = dayFormat(locale);
  const summary = [
    stats.events ? t("notifications.digest.events", { count: stats.events }) : "",
    stats.birthdays ? t("notifications.digest.birthdays", { count: stats.birthdays }) : "",
    stats.awayDays ? t("notifications.digest.away", { count: stats.awayDays }) : "",
  ].filter(Boolean);
  const lines = issues.slice(0, MAX_LINES).map((i) => `• ${fmt(i.date)} – ${issueSentence(i, t, locale)}`);
  if (issues.length > MAX_LINES) lines.push(t("notifications.digest.more", { count: issues.length - MAX_LINES }));
  if (issues.length === 0) lines.push(t("notifications.digest.allClear"));
  return {
    title: issues.length ? t("notifications.digest.title", { count: issues.length }) : t("notifications.digest.clear"),
    body: [summary.join(" · "), ...lines].filter(Boolean).join("\n"),
    url: `${getAppUrl()}/f/${familyId}/digest`,
    collapseKey: `digest:${familyId}`,
  };
}

// ---- sending ----

type DigestState = { lastSent: string };

export interface DigestSent {
  /** What the family's channels got. */
  channels: NotifyResult;
  /** Per account member: what their app devices got. */
  users: { userId: string; issues: number; result: NotifyResult }[];
}

/** Sends the family's week ahead (once a day); null when there was nothing to send (off,
 *  already sent today, an empty fortnight). */
export async function sendWeeklyDigest(
  db: Db,
  familyId: string,
  now: Date,
  opts: { send?: Sender; push?: RelayClient; today?: string } = {},
): Promise<DigestSent | null> {
  const today = opts.today ?? localDay(now);
  const state = readState<DigestState>(db, familyId, "weekly_digest");
  if (state.lastSent === today) return null;
  const pref = getPref(db, familyId, "weekly_digest");
  if (!pref.enabled) return null;
  const { digest, eventCount } = gather(db, familyId, today, addDays(today, DIGEST_DAYS - 1));
  const awayDayCount = digest.away.reduce((n, r) => n + diffDays(r.from, r.to) + 1, 0);
  writeState(db, familyId, "weekly_digest", { lastSent: today }, now);
  if (eventCount === 0 && digest.away.length === 0 && digest.birthdays.length === 0) return null;

  const locale = familyLocale(db, familyId);
  const t = translator(locale);
  const stats = { events: eventCount, birthdays: digest.birthdays.length, awayDays: awayDayCount };
  const open = digest.issues.filter((i) => !i.dismissed);

  // The channels: every conflict and warning.
  const channels = await notifyFamily(
    db,
    familyId,
    digestMessage(
      open.filter((i) => i.severity !== "info"),
      stats,
      t,
      locale,
      familyId,
    ),
    { channelIds: pref.channelIds ?? undefined, send: opts.send, event: "weekly_digest" },
  );

  // The app: each account member what concerns them.
  const users: DigestSent["users"] = [];
  if (pref.app) {
    const withoutAccount = new Set(digest.people.filter((p) => !p.account).map((p) => p.id));
    const members = db
      .select({ userId: familyMembers.userId })
      .from(familyMembers)
      .where(eq(familyMembers.familyId, familyId))
      .orderBy(asc(familyMembers.joinedAt), asc(familyMembers.userId))
      .all();
    for (const { userId } of members) {
      const theirs = open.filter(
        (i) => i.people.length === 0 || i.people.some((p) => p.id === userId || (p.id !== null && withoutAccount.has(p.id))),
      );
      const result = await notifyFamily(db, familyId, digestMessage(theirs, stats, t, locale, familyId), {
        channelIds: [],
        app: { userIds: [userId] },
        event: "weekly_digest",
        push: opts.push,
      });
      users.push({ userId, issues: theirs.length, result });
    }
  }
  return { channels, users };
}

/** When the weekly digest goes out: DIGEST_WEEKDAY (0 = Sunday … 6), from DIGEST_HOUR. */
export function digestSchedule(env: Record<string, string | undefined> = process.env): { weekday: number; hour: number } {
  const weekday = Number(env.DIGEST_WEEKDAY ?? 0);
  const hour = Number(env.DIGEST_HOUR ?? 18);
  return {
    weekday: Number.isInteger(weekday) && weekday >= 0 && weekday <= 6 ? weekday : 0,
    hour: Number.isInteger(hour) && hour >= 0 && hour <= 23 ? hour : 18,
  };
}

/** Families whose places were refreshed today (this worker process). */
const refreshedOn = new Map<string, string>();

/** One worker tick: the daily geocoding of every family's places and, on the digest's day, the
 *  week ahead. A failing family doesn't stop the others. */
export async function weeklyDigests(
  db: Db,
  now: Date,
  opts: { send?: Sender; push?: RelayClient; lookup?: PlaceLookup; env?: Record<string, string | undefined> } = {},
): Promise<void> {
  const today = localDay(now);
  const { weekday, hour } = digestSchedule(opts.env);
  const due = now.getDay() === weekday && now.getHours() >= hour;
  for (const { id } of db.select({ id: families.id }).from(families).all()) {
    try {
      if (refreshedOn.get(id) !== today) {
        refreshedOn.set(id, today);
        await refreshPlaces(db, id, today, { lookup: opts.lookup, now });
      }
      if (!due || !getPref(db, id, "weekly_digest").enabled) continue;
      if (readState<DigestState>(db, id, "weekly_digest").lastSent === today) continue;
      // Locations added since this morning (capped per day like the rest).
      await refreshPlaces(db, id, today, { lookup: opts.lookup, now });
      await sendWeeklyDigest(db, id, now, { send: opts.send, push: opts.push, today });
    } catch (e) {
      console.error(`[digest] week ahead of family ${id} failed:`, e);
    }
  }
}
