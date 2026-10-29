import { check, index, integer, primaryKey, sqliteTable, text } from "drizzle-orm/sqlite-core";
import { sql } from "drizzle-orm";
import { families, users } from "../schema";

// ---- the assistant (family-planner's ai_settings, ai_chats, ai_chat_items, ai_chat_messages).
// JSON columns are text, parsed by lib/assistant/store.ts. The chats' times are milliseconds
// (timestamp_ms): the lease of a running turn and the order of the chats need more than
// seconds.

/** The family's AI setup: one OpenAI-compatible endpoint (keys sealed with lib/secrets.ts),
 *  the web search, whether the assistant may change things, and the model's context window. */
export const aiSettings = sqliteTable("ai_settings", {
  familyId: text("family_id")
    .primaryKey()
    .references(() => families.id, { onDelete: "cascade" }),
  baseUrl: text("base_url").notNull().default(""),
  model: text("model").notNull().default(""),
  apiKeyEnc: text("api_key_enc").notNull().default(""), // sealed ("v1:…"), "" = none
  searchProvider: text("search_provider").notNull().default("none"), // none | tavily | brave
  searchKeyEnc: text("search_key_enc").notNull().default(""),
  allowWrites: integer("allow_writes", { mode: "boolean" }).notNull().default(true),
  /** Tokens; 0: from the endpoint's model list (or 128,000). */
  contextWindow: integer("context_window").notNull().default(0),
  /** The model for recipe photos (meals); "" = none. */
  imageModel: text("image_model").notNull().default(""),
  updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
});

/** A chat of one user in a family. Its turns run in the worker: a turn holds `run_token`
 *  until `run_until` (renewed while it works); a running chat without a token (or whose hold
 *  ran out) waits for the worker to take it. */
export const chats = sqliteTable(
  "chats",
  {
    id: text("id").primaryKey(),
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    title: text("title").notNull().default(""),
    status: text("status").notNull().default("idle"), // idle | running
    runToken: text("run_token"),
    runUntil: integer("run_until", { mode: "timestamp_ms" }),
    /** The user asked to stop the running turn. */
    stop: integer("stop", { mode: "boolean" }).notNull().default(false),
    /** Failed tries of the running step. */
    retries: integer("retries").notNull().default(0),
    /** JSON: page, year, language and day of the latest message. */
    context: text("context").notNull().default("{}"),
    /** JSON: what the running turn does right now, or null. */
    activity: text("activity"),
    /** JSON array: changes the user undid, which the assistant hears with the next message. */
    notes: text("notes").notNull().default("[]"),
    /** JSON {used, max}: how full the model's context was at the last step, or null. */
    usage: text("usage"),
    /** JSON array: messages written while a turn ran, to go next in order. */
    queue: text("queue").notNull().default("[]"),
    /** Counts the changes of the items. */
    rev: integer("rev").notNull().default(0),
    createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull(),
    updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull(),
  },
  (t) => ({
    chatsOwnerIdx: index("chats_owner_idx").on(t.familyId, t.userId, t.updatedAt),
    chatsStatusIdx: index("chats_status_idx").on(t.status),
    chatsStatusCheck: check("chats_status_check", sql`${t.status} in ('idle', 'running')`),
  }),
);

/** What a chat shows at one position; `rev`: the chat's revision it last changed in. */
export const chatItems = sqliteTable(
  "chat_items",
  {
    chatId: text("chat_id")
      .notNull()
      .references(() => chats.id, { onDelete: "cascade" }),
    seq: integer("seq").notNull(),
    rev: integer("rev").notNull(),
    item: text("item").notNull(), // JSON
  },
  (t) => ({
    pk: primaryKey({ columns: [t.chatId, t.seq] }),
    chatItemsRevIdx: index("chat_items_rev_idx").on(t.chatId, t.rev),
  }),
);

/** What the model gets back, in order (only ever appended); summaries are kept among them. */
export const chatMessages = sqliteTable(
  "chat_messages",
  {
    chatId: text("chat_id")
      .notNull()
      .references(() => chats.id, { onDelete: "cascade" }),
    seq: integer("seq").notNull(),
    message: text("message").notNull(), // JSON
  },
  (t) => ({ pk: primaryKey({ columns: [t.chatId, t.seq] }) }),
);
