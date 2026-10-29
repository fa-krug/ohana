import { sql } from "drizzle-orm";
import {
  blob,
  check,
  foreignKey,
  index,
  integer,
  primaryKey,
  real,
  sqliteTable,
  text,
  uniqueIndex,
} from "drizzle-orm/sqlite-core";

// ---- accounts ----

export const users = sqliteTable("users", {
  id: text("id").primaryKey(),
  /** The sign-in name: an email address, or a plain name like "admin"; lowercase. */
  email: text("email").notNull().unique(),
  name: text("name").notNull().default(""),
  password: text("password").notNull().default(""), // hash string; "" = unusable (passkey-only)
  isAdmin: integer("is_admin", { mode: "boolean" }).notNull().default(false),
  preferredLanguage: text("preferred_language").notNull().default("en"),
  /** The family "/" opens; null: the first one the user is a member of. */
  lastFamilyId: text("last_family_id").references(() => families.id, { onDelete: "set null" }),
  onboardingStep: text("onboarding_step").notNull().default("COMPLETED"),
  createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
});

/** A sign-in session, a personal API token, or a one-time setup link. Only the SHA-256
 *  of the token is stored, so a copy of the database signs nobody in. */
export const authTokens = sqliteTable(
  "auth_tokens",
  {
    id: text("id").primaryKey(),
    hash: text("hash").notNull().unique(),
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    kind: text("kind").notNull(), // session | api | setup
    name: text("name").notNull().default(""),
    /** A session opened with a setup link: may set a new password without the current one. */
    canReset: integer("can_reset", { mode: "boolean" }).notNull().default(false),
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
    lastUsedAt: integer("last_used_at", { mode: "timestamp" }),
    expiresAt: integer("expires_at", { mode: "timestamp" }),
  },
  (t) => ({
    authTokensUserKindIdx: index("auth_tokens_user_kind_idx").on(t.userId, t.kind),
  }),
);

export const passkeyCredentials = sqliteTable("passkey_credentials", {
  id: text("id").primaryKey(),
  userId: text("user_id")
    .notNull()
    .references(() => users.id, { onDelete: "cascade" }),
  credentialId: blob("credential_id", { mode: "buffer" }).notNull().unique(),
  publicKey: blob("public_key", { mode: "buffer" }).notNull(),
  signCount: integer("sign_count").notNull().default(0),
  deviceName: text("device_name").notNull().default(""),
  createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  lastUsedAt: integer("last_used_at", { mode: "timestamp" }),
});

/** Failed attempts per key (e.g. a sign-in name) and window, to slow down guessing. */
export const rateLimits = sqliteTable(
  "rate_limits",
  {
    key: text("key").notNull(),
    windowStart: integer("window_start", { mode: "timestamp" }).notNull(),
    count: integer("count").notNull().default(0),
  },
  (t) => ({ pk: primaryKey({ columns: [t.key, t.windowStart] }) }),
);

// ---- families ----

export const families = sqliteTable("families", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  /** The calendar feed's secret id: opens calendar.ics and nothing else, without signing in. */
  feedId: text("feed_id").notNull().unique(),
  /** The view id of a family-planner planner from before families (filled by the import):
   *  its feed keeps working under this id, and the feed's event UIDs keep it as prefix. */
  legacyId: text("legacy_id").unique(),
  /** Home address (geocoded with Photon): the origin for distances, e.g. to a practice. */
  homeAddress: text("home_address"),
  homeLat: real("home_lat"),
  homeLng: real("home_lng"),
  createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
});

export const familyMembers = sqliteTable(
  "family_members",
  {
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    role: text("role").notNull().default("editor"), // editor | viewer
    joinedAt: integer("joined_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({
    pk: primaryKey({ columns: [t.familyId, t.userId] }),
    familyMembersUserIdIdx: index("family_members_user_id_idx").on(t.userId),
  }),
);

export const invites = sqliteTable(
  "invites",
  {
    id: text("id").primaryKey(),
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    createdById: text("created_by_id").references(() => users.id, { onDelete: "set null" }),
    code: text("code").notNull(),
    role: text("role").notNull().default("editor"),
    expiresAt: integer("expires_at", { mode: "timestamp" }).notNull(),
    usedById: text("used_by_id").references(() => users.id, { onDelete: "set null" }),
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({ invitesCodeIdx: uniqueIndex("invites_code_idx").on(t.code) }),
);

// ---- calendar ----

/** An entry type (e.g. Vacation) belongs to one year; each year of a family has its own set. */
export const calEntryTypes = sqliteTable(
  "cal_entry_types",
  {
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    year: integer("year").notNull(),
    /** Unique within the family's year (a slug of the name, e.g. "vacation"). */
    id: text("id").notNull(),
    name: text("name").notNull(),
    color: text("color").notNull(),
    role: text("role").notNull().default("none"), // none | needs_cover | covers | day_off
    position: integer("position").notNull().default(0),
    /** The whole family is away from home on its days: the meal plan leaves them out. */
    away: integer("away", { mode: "boolean" }).notNull().default(false),
  },
  (t) => ({ pk: primaryKey({ columns: [t.familyId, t.year, t.id] }) }),
);

/** A type on a day. The type is one of the day's year (`year` is the day's year), so deleting
 *  a type deletes its entries. */
export const calEntries = sqliteTable(
  "cal_entries",
  {
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    day: text("day").notNull(), // YYYY-MM-DD
    year: integer("year").notNull(),
    typeId: text("type_id").notNull(),
  },
  (t) => ({
    pk: primaryKey({ columns: [t.familyId, t.day, t.typeId] }),
    type: foreignKey({
      columns: [t.familyId, t.year, t.typeId],
      foreignColumns: [calEntryTypes.familyId, calEntryTypes.year, calEntryTypes.id],
    }).onDelete("cascade"),
    calEntriesTypeIdx: index("cal_entries_type_idx").on(t.familyId, t.year, t.typeId),
    yearOfDay: check("cal_entries_year_of_day", sql`${t.year} = cast(substr(${t.day}, 1, 4) as integer)`),
  }),
);

/** An icon and/or comment on a day; independent of entries (no role, no coverage). */
export const calNotes = sqliteTable(
  "cal_notes",
  {
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    day: text("day").notNull(),
    icon: text("icon").notNull().default(""),
    comment: text("comment").notNull().default(""),
  },
  (t) => ({ pk: primaryKey({ columns: [t.familyId, t.day] }) }),
);

// ---- modules (one file each) ----

export * from "./schema/notifications";
export * from "./schema/appointments";
export * from "./schema/meals";
export * from "./schema/finance";
export * from "./schema/connections";
