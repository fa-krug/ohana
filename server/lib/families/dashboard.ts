// The family overview (phase 7): one dashboard over all modules. Today (meal or "away", the
// day's appointments), what comes up (calendar runs and booked appointments together), this
// month's finances, the next birthdays and the latest finds of the appointment searches.

import type { Db } from "@/lib/db";
import { addDays } from "@/lib/calendar/dates";
import { type CalendarSummary, calendarSummary } from "@/lib/calendar/summary";
import { listEvents, type PublicEvent, publicEvent } from "@/lib/calendar/events";
import { type MonthSummary, monthSummary } from "@/lib/finance/summary";
import { getMealsSummary, type MealsSummary } from "@/lib/meals/queries/meal-plan";
import { awayDays } from "@/lib/meals/meal-plan/away";
import { listSearchesWithLatest } from "@/lib/appointments/serialize";
import { type BirthdayDay, birthdaysIn } from "./birthdays";
import { familyNames } from "./people";
import { moduleEnabled } from "@/lib/server-info";

/** One line of "coming up": a run of a calendar type, or a timed event. */
export type UpcomingItem =
  | { kind: "entry"; date: string; to: string; name: string; color: string }
  | { kind: "event"; date: string; event: PublicEvent };

export interface SearchFind {
  id: string;
  name: string;
  enabled: boolean;
  lastStatus: string;
  /** The earliest find of the latest run, if any. */
  first: { resultId: number; doctorName: string; slot: string } | null;
  /** How many doctors that run found. */
  doctors: number;
}

export interface Dashboard {
  today: string;
  calendar: CalendarSummary;
  /** Names of today's "away" types (no meal is planned then). */
  awayToday: string[];
  todayEvents: PublicEvent[];
  upcoming: UpcomingItem[];
  meals: MealsSummary;
  finance: MonthSummary;
  searches: SearchFind[];
  /** Birthdays from today to 29 days on, by day (with the age they turn). */
  birthdays: BirthdayDay[];
}

const UPCOMING_DAYS = 30;

export async function familyDashboard(
  db: Db,
  familyId: string,
  today: string,
  { limit = 8 }: { limit?: number } = {},
): Promise<Dashboard> {
  const until = addDays(today, UPCOMING_DAYS);
  const [calendar, finance] = await Promise.all([
    calendarSummary(db, familyId, today, { days: UPCOMING_DAYS, limit }),
    monthSummary(db, familyId, today),
  ]);
  const events = listEvents(db, familyId, { from: today, to: until }).map(publicEvent);
  const upcoming: UpcomingItem[] = [
    ...calendar.upcoming.map((u) => ({ kind: "entry" as const, date: u.from, to: u.to, name: u.name, color: u.color })),
    ...events.filter((e) => e.date > today).map((event) => ({ kind: "event" as const, date: event.date, event })),
  ];
  // Runs that started earlier (still going) sort as today.
  const key = (i: UpcomingItem) => (i.date < today ? today : i.date);
  upcoming.sort(
    (a, b) =>
      key(a).localeCompare(key(b)) ||
      (a.kind === "event" && b.kind === "event" ? (a.event.start ?? "").localeCompare(b.event.start ?? "") : 0) ||
      (a.kind === b.kind ? 0 : a.kind === "event" ? 1 : -1),
  );
  const searches = (moduleEnabled("appointments") ? listSearchesWithLatest(db, familyId) : []).map((s) => ({
    id: s.id,
    name: s.name,
    enabled: s.enabled,
    lastStatus: s.lastStatus,
    first: s.doctors[0] ? { resultId: s.doctors[0].resultId, doctorName: s.doctors[0].doctorName, slot: s.doctors[0].slot } : null,
    doctors: s.doctors.length,
  }));
  return {
    today,
    calendar,
    awayToday: awayDays(db, familyId, today, today).get(today) ?? [],
    todayEvents: events.filter((e) => e.date === today),
    upcoming: upcoming.slice(0, limit),
    meals: getMealsSummary(db, familyId, today),
    finance,
    searches,
    birthdays: birthdaysIn(familyNames(db, familyId), today, addDays(today, UPCOMING_DAYS - 1)),
  };
}
