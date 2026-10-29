// The worker's daily notifications (phase 7), one check per family and kind:
//
// - coverage_gap: weekdays in the next 14 days that need cover (e.g. a day-care closure) but
//   have none. One message listing them, at most once a day (from NOTIFY_HOUR), and only when
//   a day is among them that wasn't notified before: the days already told about are kept
//   (and dropped once covered, so a day that loses its cover again is told again).
// - shopping_reminder: the evening before a shopping day (from SHOPPING_REMINDER_HOUR), what is
//   still on that day's shopping list; once per shopping day.
//
// Days are the server's local days (the container's TZ), like the backup hour.

import { and, asc, desc, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { families, ingredients, mealPlans, planIterations, shoppingListItems, shoppingLists, units } from "@/lib/db/schema";
import { getAppUrl } from "@/lib/auth/config";
import { addDays, consecutiveRuns } from "@/lib/calendar/dates";
import { gapDays } from "@/lib/calendar/ics";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import type { Sender } from "./index";
import { familyLocale, translator } from "./locale";
import { notifyEvent, readState, writeState } from "./prefs";
import { formatQuantity } from "@/lib/meals/display/format";

export const COVERAGE_DAYS = 14;
const MAX_ITEMS = 30;

/** The server's local calendar day ("YYYY-MM-DD"). */
export function localDay(now: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;
}

function dayFormat(locale: string) {
  const f = new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", {
    weekday: "short",
    day: "numeric",
    month: "short",
    timeZone: "UTC",
  });
  return (d: string) => f.format(new Date(`${d}T00:00:00Z`));
}

/** Weekdays from `today` on (COVERAGE_DAYS days) that need cover and have none, each with the
 *  names of the types that need it. */
export async function uncoveredDays(db: Db, familyId: string, today: string): Promise<Map<string, string[]>> {
  const store = new DrizzleCalendarStore(db);
  const to = addDays(today, COVERAGE_DAYS - 1);
  const [types, rows] = await Promise.all([store.listTypes(familyId), store.listEntries(familyId, today, to)]);
  const entries = new Map<string, string[]>();
  for (const r of rows) entries.set(r.day, [...(entries.get(r.day) ?? []), r.type_id]);
  const out = new Map<string, string[]>();
  for (const day of gapDays(types, entries)) {
    const ids = entries.get(day) ?? [];
    const names = types
      .filter((t) => t.year === Number(day.slice(0, 4)) && t.role === "needs_cover" && ids.includes(t.id))
      .map((t) => t.name);
    out.set(day, names);
  }
  return out;
}

type CoverageState = { lastCheck: string; notified: string[] };

/** The daily coverage check of one family; returns the days it told about (empty: nothing). */
export async function checkCoverage(
  db: Db,
  familyId: string,
  now: Date,
  opts: { send?: Sender; today?: string } = {},
): Promise<string[]> {
  const today = opts.today ?? localDay(now);
  const state = readState<CoverageState>(db, familyId, "coverage_gap");
  if (state.lastCheck === today) return [];
  const gaps = await uncoveredDays(db, familyId, today);
  const days = [...gaps.keys()].sort();
  const known = (state.notified ?? []).filter((d) => gaps.has(d));
  const fresh = days.filter((d) => !known.includes(d));
  if (!fresh.length) {
    writeState(db, familyId, "coverage_gap", { lastCheck: today, notified: known }, now);
    return [];
  }
  const t = translator(familyLocale(db, familyId));
  const fmt = dayFormat(familyLocale(db, familyId));
  const lines = consecutiveRuns(days).map((run) => {
    const span = run.length === 1 ? fmt(run[0]) : `${fmt(run[0])} – ${fmt(run[run.length - 1])}`;
    const names = [...new Set(run.flatMap((d) => gaps.get(d) ?? []))].join(", ");
    // Marked only next to days told about before.
    const isNew = known.length > 0 && run.some((d) => fresh.includes(d));
    return `• ${span}${names ? ` (${names})` : ""}${isNew ? ` – ${t("notifications.coverage.new")}` : ""}`;
  });
  const res = await notifyEvent(
    db,
    familyId,
    "coverage_gap",
    {
      title: t("notifications.coverage.title", { count: days.length }),
      body: lines.join("\n"),
      url: `${getAppUrl()}/f/${familyId}/calendar`,
    },
    { send: opts.send },
  );
  const sent = !!res && res.sent > 0;
  // Told: remember the days. Not told (off, no channel or all failed): try again tomorrow.
  writeState(db, familyId, "coverage_gap", { lastCheck: today, notified: sent ? days : known }, now);
  return sent ? days : [];
}

type ShoppingState = { lastDate: string };

/** The shopping list of `day` (the newest, if a plan was renewed), with what is still to buy. */
export function shoppingListFor(db: Db, familyId: string, day: string, locale: "en" | "de") {
  const list = db
    .select({ id: shoppingLists.id })
    .from(shoppingLists)
    .innerJoin(planIterations, eq(planIterations.id, shoppingLists.iterationId))
    .innerJoin(mealPlans, eq(mealPlans.id, planIterations.mealPlanId))
    .where(and(eq(mealPlans.familyId, familyId), eq(shoppingLists.shoppingDate, day)))
    .orderBy(desc(shoppingLists.createdAt))
    .get();
  if (!list) return null;
  const items = db
    .select({
      name: locale === "de" ? ingredients.nameDe : ingredients.nameEn,
      quantity: shoppingListItems.quantity,
      unit: units.abbreviation,
    })
    .from(shoppingListItems)
    .innerJoin(ingredients, eq(ingredients.id, shoppingListItems.ingredientId))
    .innerJoin(units, eq(units.id, shoppingListItems.unitId))
    .where(and(eq(shoppingListItems.shoppingListId, list.id), eq(shoppingListItems.isChecked, false)))
    .orderBy(asc(locale === "de" ? ingredients.nameDe : ingredients.nameEn))
    .all();
  return { id: list.id, items };
}

/** The evening reminder of one family: tomorrow's shopping list, once per shopping day. */
export async function remindShopping(
  db: Db,
  familyId: string,
  now: Date,
  opts: { send?: Sender; today?: string } = {},
): Promise<boolean> {
  const tomorrow = addDays(opts.today ?? localDay(now), 1);
  const state = readState<ShoppingState>(db, familyId, "shopping_reminder");
  if (state.lastDate === tomorrow) return false;
  const locale = familyLocale(db, familyId);
  const list = shoppingListFor(db, familyId, tomorrow, locale);
  if (!list || !list.items.length) return false;
  const t = translator(locale);
  const shown = list.items.slice(0, MAX_ITEMS).map((i) => `• ${[formatQuantity(i.quantity), i.unit, i.name].filter(Boolean).join(" ")}`);
  if (list.items.length > MAX_ITEMS) shown.push(t("notifications.shopping.more", { count: list.items.length - MAX_ITEMS }));
  const res = await notifyEvent(
    db,
    familyId,
    "shopping_reminder",
    {
      title: t("notifications.shopping.title", { count: list.items.length }),
      body: shown.join("\n"),
      url: `${getAppUrl()}/f/${familyId}/meals/shopping/${list.id}`,
    },
    { send: opts.send },
  );
  if (!res) return false; // turned off: nothing remembered, so turning it on still reminds
  writeState(db, familyId, "shopping_reminder", { lastDate: tomorrow }, now);
  return res.sent > 0;
}

/** Hour of day (server time) from which the coverage check runs. */
const NOTIFY_HOUR = Number(process.env.NOTIFY_HOUR ?? 7);
/** Hour of day (server time) from which tomorrow's shopping list is sent. */
const SHOPPING_REMINDER_HOUR = Number(process.env.SHOPPING_REMINDER_HOUR ?? 18);

/** One worker tick: the due checks of every family. A failing family doesn't stop the others. */
export async function dailyNotifications(db: Db, now: Date): Promise<void> {
  const hour = now.getHours();
  if (hour < NOTIFY_HOUR && hour < SHOPPING_REMINDER_HOUR) return;
  for (const { id } of db.select({ id: families.id }).from(families).all()) {
    try {
      if (hour >= NOTIFY_HOUR) await checkCoverage(db, id, now);
      if (hour >= SHOPPING_REMINDER_HOUR) await remindShopping(db, id, now);
    } catch (e) {
      console.error(`[notifications] daily check of family ${id} failed:`, e);
    }
  }
}
