import { type AnySQLiteColumn, index, integer, primaryKey, sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core";
import { families, users } from "../schema";

// ---- connections between the modules (phase 7) ----

/** An event on the calendar, e.g. a booked doctor's appointment: one day or several
 *  (`day` .. `endDay`, inclusive), all day (`start` null) or timed (`start` / `end` the family's
 *  wall-clock "HH:MM"; `end` is the time on `endDay`), once or repeating (`rrule`, an RFC 5545
 *  RRULE value; `day` is the first occurrence). `exdates` are occurrences taken out of a series;
 *  a changed single occurrence is a row of its own with `seriesId` (the series' row) and
 *  `occurrence` (the date it replaces), never with a rule. Shown on its days in the calendar
 *  and on the overview (lib/calendar/events.ts expands the series). */
export const calEvents = sqliteTable(
  "cal_events",
  {
    id: text("id").primaryKey(),
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    day: text("day").notNull(), // YYYY-MM-DD, the first day
    endDay: text("end_day").notNull(), // YYYY-MM-DD, the last day (>= day)
    start: text("start"), // HH:MM, null: all day
    end: text("end"), // HH:MM on endDay, null: none given
    title: text("title").notNull(),
    location: text("location").notNull().default(""),
    /** Who it is for (e.g. a child's name). */
    person: text("person").notNull().default(""),
    note: text("note").notNull().default(""),
    /** A link, e.g. the booking page of the practice. */
    url: text("url").notNull().default(""),
    /** RFC 5545 RRULE value (without "RRULE:"), e.g. "FREQ=WEEKLY;BYDAY=MO"; null: once. */
    rrule: text("rrule"),
    /** JSON array of the series' occurrences ("YYYY-MM-DD") that were removed. */
    exdates: text("exdates").notNull().default("[]"),
    /** An override of one occurrence: the series it belongs to, and the date it replaces. */
    seriesId: text("series_id").references((): AnySQLiteColumn => calEvents.id, { onDelete: "cascade" }),
    occurrence: text("occurrence"),
    /** Where it came from: "manual" | "appointment" | "apple". With an appointment, `sourceId`
     *  is the search's id and `sourceItem` the result's (the slot's details are copied: results
     *  are pruned after 30 days, the event stays). With "apple" (imported from Apple Calendar by
     *  the app) `sourceItem` is the Apple event's identifier, `sourceId` null. */
    source: text("source").notNull().default("manual"),
    sourceId: text("source_id"),
    sourceItem: text("source_item"),
    createdById: text("created_by_id").references(() => users.id, { onDelete: "set null" }),
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({
    calEventsFamilyDayIdx: index("cal_events_family_day_idx").on(t.familyId, t.day),
    calEventsSeriesOccurrenceIdx: uniqueIndex("cal_events_series_occurrence_idx").on(t.seriesId, t.occurrence),
  }),
);

/** Per family and event kind (appointment_found, coverage_gap, assistant_turn_finished): whether it
 *  is sent and to which channels, plus what was sent last (so nothing repeats). A missing row
 *  means the defaults (lib/notifications/prefs.ts). */
export const notificationPrefs = sqliteTable(
  "notification_prefs",
  {
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    event: text("event").notNull(),
    enabled: integer("enabled", { mode: "boolean" }).notNull(),
    /** JSON array of channel ids; null: all of the family's enabled channels. */
    channelIds: text("channel_ids"),
    /** Also push to the members' app devices (phase 9). */
    app: integer("app", { mode: "boolean" }).notNull().default(true),
    /** JSON: the event's memory (e.g. the days already notified, the last check). */
    state: text("state").notNull().default("{}"),
    updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({ pk: primaryKey({ columns: [t.familyId, t.event] }) }),
);
