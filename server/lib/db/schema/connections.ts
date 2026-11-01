import { index, integer, primaryKey, sqliteTable, text } from "drizzle-orm/sqlite-core";
import { families, users } from "../schema";

// ---- connections between the modules (phase 7) ----

/** A timed event on a calendar day, e.g. a booked doctor's appointment. Shown on its day in the
 *  calendar, on the overview and (optionally) in the calendar feed. `start` / `end` are the
 *  wall-clock time ("HH:MM") of the family; no `start`: all day. */
export const calEvents = sqliteTable(
  "cal_events",
  {
    id: text("id").primaryKey(),
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    day: text("day").notNull(), // YYYY-MM-DD
    start: text("start"), // HH:MM, null: all day
    end: text("end"), // HH:MM, null: none given
    title: text("title").notNull(),
    location: text("location").notNull().default(""),
    /** Who it is for (e.g. a child's name). */
    person: text("person").notNull().default(""),
    note: text("note").notNull().default(""),
    /** A link, e.g. the booking page of the practice. */
    url: text("url").notNull().default(""),
    /** Where it came from: "manual" | "appointment". With an appointment, `sourceId` is the
     *  search's id and `sourceItem` the result's (the slot's details are copied: results are
     *  pruned after 30 days, the event stays). */
    source: text("source").notNull().default("manual"),
    sourceId: text("source_id"),
    sourceItem: text("source_item"),
    createdById: text("created_by_id").references(() => users.id, { onDelete: "set null" }),
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({ calEventsFamilyDayIdx: index("cal_events_family_day_idx").on(t.familyId, t.day) }),
);

/** Per family and event kind (appointment_found, coverage_gap, shopping_reminder): whether it
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
