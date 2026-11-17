import { index, primaryKey, integer, sqliteTable, text } from "drizzle-orm/sqlite-core";
import { families, familyPeople, users } from "../schema";

// ---- health: check-ups and vaccinations (lib/health) ----

/** A check-up or vaccination of the schedule (lib/health/schedule.ts `code`) someone had (or
 *  skipped): a member's account (`memberUserId`) or a member without one (`memberPersonId`).
 *  One per code, except the repeating ones (tetanus, flu …): one per time. */
export const healthRecords = sqliteTable(
  "health_records",
  {
    id: text("id").primaryKey(),
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    memberUserId: text("member_user_id").references(() => users.id, { onDelete: "cascade" }),
    memberPersonId: text("member_person_id").references(() => familyPeople.id, { onDelete: "cascade" }),
    code: text("code").notNull(),
    /** YYYY-MM-DD; null: done, the date isn't known. */
    day: text("day"),
    /** "done" | "skipped". */
    status: text("status").notNull().default("done"),
    note: text("note").notNull().default(""),
    createdById: text("created_by_id").references(() => users.id, { onDelete: "set null" }),
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
    updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({ healthRecordsFamilyIdx: index("health_records_family_idx").on(t.familyId) }),
);

/** The reminders the worker pushed, once each: `key` is "<code>:<window start>:<open|closing>". */
export const healthNotified = sqliteTable(
  "health_notified",
  {
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    memberId: text("member_id").notNull(),
    key: text("key").notNull(),
    sentAt: integer("sent_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({ pk: primaryKey({ columns: [t.familyId, t.memberId, t.key] }) }),
);
