import { index, integer, primaryKey, sqliteTable, text } from "drizzle-orm/sqlite-core";
import { families } from "../schema";

// ---- public and school holidays (lib/calendar/holidays) ----

/** Whether the family imports public and / or school holidays, and for which region: an
 *  OpenHolidays code ("DE", "DE-BY", "DE-BY-AU"), detected from the home address while
 *  `regionAuto` (`regionFrom`: the "lat,lng" it was detected for) or fixed. `regionNames`: the
 *  region's name by language (JSON, `{"de": "Bayern, Deutschland", …}`); `syncedRegion`: the
 *  region the recorded days were imported for, `importFrom`: the first day the sync adds (the
 *  day the region last changed; null: the window's start). A sync is wanted from `requestedAt` on (a
 *  failed one moves it later); `status`: null | ok | no_address | unsupported | failed. */
export const holidaySettings = sqliteTable(
  "holiday_settings",
  {
    familyId: text("family_id")
      .primaryKey()
      .references(() => families.id, { onDelete: "cascade" }),
    publicHolidays: integer("public_holidays", { mode: "boolean" }).notNull().default(false),
    schoolHolidays: integer("school_holidays", { mode: "boolean" }).notNull().default(false),
    region: text("region"),
    regionAuto: integer("region_auto", { mode: "boolean" }).notNull().default(true),
    regionFrom: text("region_from"),
    regionNames: text("region_names"),
    syncedRegion: text("synced_region"),
    importFrom: text("import_from"),
    requestedAt: integer("requested_at", { mode: "timestamp" }),
    syncedAt: integer("synced_at", { mode: "timestamp" }),
    status: text("status"),
  },
  (t) => ({ holidaySettingsRequestedIdx: index("holiday_settings_requested_idx").on(t.requestedAt) }),
);

/** The days the import wrote as entries, per kind ("public" | "school"): a day the user
 *  deleted stays deleted, a day the source drops is removed again. */
export const holidayDays = sqliteTable(
  "holiday_days",
  {
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    kind: text("kind").notNull(),
    day: text("day").notNull(), // YYYY-MM-DD
  },
  (t) => ({ pk: primaryKey({ columns: [t.familyId, t.kind, t.day] }) }),
);

/** OpenHolidays' holidays of a country, kind and year, shared by all families: `data` is JSON,
 *  the full-day ones normalized (`openholidays.ts` `CachedHoliday[]`). Refetched after a week; a
 *  failed fetch keeps the old copy. */
export const holidayCache = sqliteTable(
  "holiday_cache",
  {
    country: text("country").notNull(),
    kind: text("kind").notNull(),
    year: integer("year").notNull(),
    data: text("data").notNull(),
    fetchedAt: integer("fetched_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({ pk: primaryKey({ columns: [t.country, t.kind, t.year] }) }),
);
