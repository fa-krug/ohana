import { index, integer, sqliteTable, text } from "drizzle-orm/sqlite-core";
import { families, familyPeople, users } from "../schema";

// ---- chores ----

/** A chore of the family: once (due on `day`) or repeating (`rrule`, an RFC 5545 RRULE value
 *  as calendar events have; `day` is the first occurrence), assigned to at most one person:
 *  a member's account (`assigneeUserId`) or a member without one (`assigneePersonId`). Only a
 *  single chore is ever done (`doneAt`); the app turns chores into reminders (lib/chores). */
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
    /** RFC 5545 RRULE value (without "RRULE:"); null: once. */
    rrule: text("rrule"),
    /** When a single chore was done; null: open. */
    doneAt: integer("done_at", { mode: "timestamp" }),
    createdById: text("created_by_id").references(() => users.id, { onDelete: "set null" }),
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
    updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({ choresFamilyIdx: index("chores_family_idx").on(t.familyId) }),
);
