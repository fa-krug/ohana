import { index, integer, sqliteTable, text } from "drizzle-orm/sqlite-core";
import { families } from "../schema";

// ---- notification channels (family-wide, shared by every module) ----

/** Where a family's notifications go. `token` holds the secret (API key, bot token or
 *  SMTP password), sealed with lib/secrets.ts; it never leaves the server. */
export const notificationChannels = sqliteTable(
  "notification_channels",
  {
    id: text("id").primaryKey(),
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    name: text("name").notNull(),
    provider: text("provider").notNull().default("PUSHBULLET"), // PUSHBULLET | PUSHOVER | TELEGRAM | EMAIL
    token: text("token").notNull().default(""), // sealed secret ("v1:…"), "" = none
    target: text("target").notNull().default(""), // user key / chat id / recipient email
    // SMTP config (EMAIL only; blank/default for the others):
    smtpHost: text("smtp_host").notNull().default(""),
    smtpPort: integer("smtp_port").notNull().default(465),
    smtpUsername: text("smtp_username").notNull().default(""),
    smtpFrom: text("smtp_from").notNull().default(""),
    enabled: integer("enabled", { mode: "boolean" }).notNull().default(true),
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({ notificationChannelsFamilyIdx: index("notification_channels_family_idx").on(t.familyId) }),
);
