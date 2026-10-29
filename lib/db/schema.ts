import {
  blob,
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

// ---- modules (one file each) ----

export * from "./schema/notifications";
export * from "./schema/appointments";
