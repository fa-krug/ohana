import { index, integer, primaryKey, sqliteTable, text } from "drizzle-orm/sqlite-core";
import { families, familyPeople, users } from "../schema";

// ---- chores ----

/** A chore of the family: once (due on `day`) or repeating (`rrule`, an RFC 5545 RRULE value
 *  as calendar events have; `day` is the first occurrence), assigned to at most one person:
 *  a member's account (`assigneeUserId`) or a member without one (`assigneePersonId`), in a
 *  part of the day (`part`, from `time` when it has one). A single chore is done with
 *  `doneAt` / `doneById`, a repeating one per occurrence (`choreCompletions`). */
export const chores = sqliteTable(
  "chores",
  {
    id: text("id").primaryKey(),
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    title: text("title").notNull(),
    note: text("note").notNull().default(""),
    assigneeUserId: text("assignee_user_id").references(() => users.id, { onDelete: "set null" }),
    assigneePersonId: text("assignee_person_id").references(() => familyPeople.id, { onDelete: "set null" }),
    day: text("day").notNull(), // YYYY-MM-DD
    time: text("time"), // HH:MM, null: all day
    /** "morning" | "day" | "evening" (from `time` when it has one). */
    part: text("part").notNull().default("day"),
    /** RFC 5545 RRULE value (without "RRULE:"); null: once. */
    rrule: text("rrule"),
    /** When a single chore was done; null: open. */
    doneAt: integer("done_at", { mode: "timestamp" }),
    /** Who ticked a single chore off. */
    doneById: text("done_by_id").references(() => users.id, { onDelete: "set null" }),
    createdById: text("created_by_id").references(() => users.id, { onDelete: "set null" }),
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
    updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({ choresFamilyIdx: index("chores_family_idx").on(t.familyId) }),
);

/** A repeating chore's occurrence that was ticked off. */
export const choreCompletions = sqliteTable(
  "chore_completions",
  {
    choreId: text("chore_id")
      .notNull()
      .references(() => chores.id, { onDelete: "cascade" }),
    day: text("day").notNull(), // YYYY-MM-DD, an occurrence
    doneById: text("done_by_id").references(() => users.id, { onDelete: "set null" }),
    doneAt: integer("done_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({ pk: primaryKey({ columns: [t.choreId, t.day] }) }),
);

/** The accounts that get a notification when the chore is due. */
export const choreSubscribers = sqliteTable(
  "chore_subscribers",
  {
    choreId: text("chore_id")
      .notNull()
      .references(() => chores.id, { onDelete: "cascade" }),
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
  },
  (t) => ({ pk: primaryKey({ columns: [t.choreId, t.userId] }) }),
);

/** The occurrences (a single chore: its day) whose notification went out, once each. */
export const choreNotified = sqliteTable(
  "chore_notified",
  {
    choreId: text("chore_id")
      .notNull()
      .references(() => chores.id, { onDelete: "cascade" }),
    day: text("day").notNull(), // YYYY-MM-DD
    sentAt: integer("sent_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({ pk: primaryKey({ columns: [t.choreId, t.day] }) }),
);

/** When the family's parts of the day start ("HH:MM", morning < day < evening; no row: the
 *  defaults, lib/chores/day-parts.ts). A time before `day` is the morning's, before `evening`
 *  the day's, else the evening's; a chore without a time is due when its part starts. */
export const choreDayParts = sqliteTable("chore_day_parts", {
  familyId: text("family_id")
    .primaryKey()
    .references(() => families.id, { onDelete: "cascade" }),
  morning: text("morning").notNull(),
  day: text("day").notNull(),
  evening: text("evening").notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
});
