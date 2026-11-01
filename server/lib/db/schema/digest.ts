import { integer, primaryKey, real, sqliteTable, text } from "drizzle-orm/sqlite-core";
import { families, users } from "../schema";

// ---- the week ahead (phase 11) ----

/** Event locations geocoded by the worker (lib/digest/geo.ts), per family: `query` is the
 *  location as typed, normalized (lib/digest/travel.ts `placeKey`). A miss has no coordinates
 *  (`lat` / `lng` null) and is tried again after a week; a hit is refreshed after half a year. */
export const geoPlaces = sqliteTable(
  "geo_places",
  {
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    query: text("query").notNull(),
    lat: real("lat"),
    lng: real("lng"),
    lookedUpAt: integer("looked_up_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({ pk: primaryKey({ columns: [t.familyId, t.query] }) }),
);

/** Issues of the week ahead an editor marked "Looks fine": hidden for good (the key names the
 *  check and the occurrences it is about), pruned once `day` (the last day it concerns) passed. */
export const digestDismissals = sqliteTable(
  "digest_dismissals",
  {
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    key: text("key").notNull(),
    day: text("day").notNull(), // YYYY-MM-DD
    createdById: text("created_by_id").references(() => users.id, { onDelete: "set null" }),
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({ pk: primaryKey({ columns: [t.familyId, t.key] }) }),
);
