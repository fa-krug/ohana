// Storage of the assistant: the AI part of family-planner's `Store` interface (_shared/store.ts:
// AI settings, chats, their items and messages) over Drizzle/SQLite, with its snake_case rows
// and ISO times, so routes.ts and chats.ts work on it as they did on Supabase. What family-
// planner did in SQL functions (the revision of a chat's items, its queue) runs here in
// immediate transactions, so the web process and the worker never step on each other.

import { and, asc, desc, eq, gt, inArray, isNull, lt, or, sql } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { aiSettings, chatItems, chatMessages, chats } from "@/lib/db/schema";

export type SearchProvider = "none" | "tavily" | "brave";
export const SEARCH_PROVIDERS: SearchProvider[] = ["none", "tavily", "brave"];

/** The AI assistant's settings; the keys are sealed (lib/secrets.ts). */
export interface AiSettingsRow {
  family_id: string;
  base_url: string;
  model: string;
  api_key_enc: string;
  search_provider: SearchProvider;
  search_key_enc: string;
  allow_writes: boolean;
  /** The model's context window in tokens; 0: found out from the endpoint. */
  context_window: number;
  /** The model for recipe photos (meals); "" = none. */
  image_model: string;
  updated_at: string;
}

export type ChatStatus = "idle" | "running";

/** An AI chat of one user in a family; its turns run in the worker (see chats.ts). */
export interface ChatRow {
  id: string;
  family_id: string;
  user_id: string;
  title: string;
  status: ChatStatus;
  /** The running turn: the worker holding the token runs it, until `run_until`. A running
   *  chat without a token waits for the worker to take it. */
  run_token: string | null;
  run_until: string | null;
  /** The user asked to stop the running turn. */
  stop: boolean;
  /** Failed tries of the running step. */
  retries: number;
  /** Page, year, language and day of the latest message. */
  context: Record<string, unknown>;
  /** What the running turn does right now. */
  activity: Record<string, unknown> | null;
  /** Changes the user undid, for the model with the next message. */
  notes: string[];
  /** How full the model's context was at the last step: {used, max} tokens. */
  usage: Record<string, unknown> | null;
  /** Messages written while a turn ran, to go next in order (each has an `id`). */
  queue: Record<string, unknown>[];
  /** Counts the changes of the items. */
  rev: number;
  /** When someone last followed the chat (ISO), or null. */
  seen_at?: string | null;
  created_at: string;
  updated_at: string;
}

export type ChatPatch = Partial<
  Pick<
    ChatRow,
    | "title"
    | "status"
    | "run_token"
    | "run_until"
    | "stop"
    | "retries"
    | "context"
    | "activity"
    | "notes"
    | "usage"
    | "updated_at"
  >
>;

/** What the chat shows at one position; `rev`: the chat's revision it last changed in. */
export interface ChatItemRow {
  seq: number;
  rev: number;
  item: Record<string, unknown>;
}

/** What the model gets back, in order. */
export interface ChatMessageRow {
  seq: number;
  message: Record<string, unknown>;
}

/** A chat the worker can take: a turn that waits for it (or whose worker died), or messages
 *  that wait in an idle chat. `held`: a worker held it before (a takeover). */
export interface PendingChat {
  id: string;
  status: ChatStatus;
  held: boolean;
}

export interface AssistantStore {
  getAiSettings(familyId: string): Promise<AiSettingsRow | null>;
  saveAiSettings(row: AiSettingsRow): Promise<void>;
  /** The user's chats in the family, the latest first. */
  listChats(familyId: string, userId: string): Promise<ChatRow[]>;
  getChat(id: string): Promise<ChatRow | null>;
  createChat(row: ChatRow): Promise<void>;
  /** Changes the chat (with `token`: only while that run holds it); the chat after, or null. */
  updateChat(id: string, patch: ChatPatch, token?: string): Promise<ChatRow | null>;
  /** Takes the chat's turn for `token` until `until`: `start` an idle chat's turn, or `resume`
   *  a running one that the token holds or nobody holds any more. The chat after, or null. */
  claimChat(id: string, token: string, until: string, mode: "start" | "resume"): Promise<ChatRow | null>;
  /** Adds a message to the end of the chat's queue; the chat after, or null if it is gone. */
  queueChatMessage(id: string, entry: Record<string, unknown>): Promise<ChatRow | null>;
  /** Takes the message `entryId` out of the chat's queue; the chat after, or null if the
   *  message (or the chat) is gone, so only one of two callers gets it. */
  unqueueChatMessage(id: string, entryId: string): Promise<ChatRow | null>;
  /** Deletes the chat with its items and messages. */
  deleteChat(id: string): Promise<void>;
  /** Items changed after revision `since`, by position. */
  listChatItems(chatId: string, since?: number): Promise<ChatItemRow[]>;
  /** Inserts or replaces items (by position); they get the chat's next revision, returned
   *  (null if the chat is gone). */
  putChatItems(chatId: string, items: Omit<ChatItemRow, "rev">[]): Promise<number | null>;
  listChatMessages(chatId: string): Promise<ChatMessageRow[]>;
  addChatMessages(chatId: string, rows: ChatMessageRow[]): Promise<void>;
  /** Someone follows the chat right now. */
  markChatSeen?(chatId: string, at: Date): Promise<void>;
}

type ChatRecord = typeof chats.$inferSelect;
type SettingsRecord = typeof aiSettings.$inferSelect;

function parse<T>(text: string | null, fallback: T): T {
  if (text === null) return fallback;
  try {
    return JSON.parse(text) as T;
  } catch {
    return fallback;
  }
}

const iso = (d: Date | null) => (d ? d.toISOString() : null);
const date = (s: string) => new Date(s);

export function chatRow(c: ChatRecord): ChatRow {
  return {
    id: c.id,
    family_id: c.familyId,
    user_id: c.userId,
    title: c.title,
    status: c.status === "running" ? "running" : "idle",
    run_token: c.runToken,
    run_until: iso(c.runUntil),
    stop: c.stop,
    retries: c.retries,
    context: parse(c.context, {}),
    activity: parse(c.activity, null),
    notes: parse(c.notes, []),
    usage: parse(c.usage, null),
    queue: parse(c.queue, []),
    rev: c.rev,
    seen_at: iso(c.seenAt),
    created_at: c.createdAt.toISOString(),
    updated_at: c.updatedAt.toISOString(),
  };
}

function settingsRow(r: SettingsRecord): AiSettingsRow {
  return {
    family_id: r.familyId,
    base_url: r.baseUrl,
    model: r.model,
    api_key_enc: r.apiKeyEnc,
    search_provider: SEARCH_PROVIDERS.includes(r.searchProvider as SearchProvider)
      ? (r.searchProvider as SearchProvider)
      : "none",
    search_key_enc: r.searchKeyEnc,
    allow_writes: r.allowWrites,
    context_window: r.contextWindow,
    image_model: r.imageModel,
    updated_at: r.updatedAt.toISOString(),
  };
}

/** A patch of a chat as columns. */
function columns(patch: ChatPatch): Partial<ChatRecord> {
  const out: Partial<ChatRecord> = {};
  if (patch.title !== undefined) out.title = patch.title;
  if (patch.status !== undefined) out.status = patch.status;
  if (patch.run_token !== undefined) out.runToken = patch.run_token;
  if (patch.run_until !== undefined) out.runUntil = patch.run_until === null ? null : date(patch.run_until);
  if (patch.stop !== undefined) out.stop = patch.stop;
  if (patch.retries !== undefined) out.retries = patch.retries;
  if (patch.context !== undefined) out.context = JSON.stringify(patch.context);
  if (patch.activity !== undefined) out.activity = patch.activity === null ? null : JSON.stringify(patch.activity);
  if (patch.notes !== undefined) out.notes = JSON.stringify(patch.notes);
  if (patch.usage !== undefined) out.usage = patch.usage === null ? null : JSON.stringify(patch.usage);
  if (patch.updated_at !== undefined) out.updatedAt = date(patch.updated_at);
  return out;
}

/** The assistant's store over Ohana's database. Calls run synchronously (better-sqlite3); they
 *  return promises to keep family-planner's interface. */
export class DrizzleAssistantStore implements AssistantStore {
  constructor(private db: Db) {}

  async getAiSettings(familyId: string) {
    const r = this.db.select().from(aiSettings).where(eq(aiSettings.familyId, familyId)).get();
    return r ? settingsRow(r) : null;
  }

  async saveAiSettings(row: AiSettingsRow) {
    const values = {
      baseUrl: row.base_url,
      model: row.model,
      apiKeyEnc: row.api_key_enc,
      searchProvider: row.search_provider,
      searchKeyEnc: row.search_key_enc,
      allowWrites: row.allow_writes,
      contextWindow: row.context_window,
      imageModel: row.image_model ?? "",
      updatedAt: date(row.updated_at),
    };
    this.db
      .insert(aiSettings)
      .values({ familyId: row.family_id, ...values })
      .onConflictDoUpdate({ target: aiSettings.familyId, set: values })
      .run();
  }

  async listChats(familyId: string, userId: string) {
    return this.db
      .select()
      .from(chats)
      .where(and(eq(chats.familyId, familyId), eq(chats.userId, userId)))
      .orderBy(desc(chats.updatedAt), desc(chats.createdAt))
      .all()
      .map(chatRow);
  }

  async markChatSeen(id: string, at: Date) {
    this.db.update(chats).set({ seenAt: at }).where(eq(chats.id, id)).run();
  }

  async getChat(id: string) {
    const c = this.db.select().from(chats).where(eq(chats.id, id)).get();
    return c ? chatRow(c) : null;
  }

  async createChat(row: ChatRow) {
    this.db
      .insert(chats)
      .values({
        id: row.id,
        familyId: row.family_id,
        userId: row.user_id,
        title: row.title,
        status: row.status,
        runToken: row.run_token,
        runUntil: row.run_until ? date(row.run_until) : null,
        stop: row.stop,
        retries: row.retries,
        context: JSON.stringify(row.context),
        activity: row.activity ? JSON.stringify(row.activity) : null,
        notes: JSON.stringify(row.notes),
        usage: row.usage ? JSON.stringify(row.usage) : null,
        queue: JSON.stringify(row.queue),
        rev: row.rev,
        createdAt: date(row.created_at),
        updatedAt: date(row.updated_at),
      })
      .run();
  }

  async updateChat(id: string, patch: ChatPatch, token?: string) {
    const set = columns(patch);
    const where = token === undefined ? eq(chats.id, id) : and(eq(chats.id, id), eq(chats.runToken, token));
    if (!Object.keys(set).length) {
      const c = this.db.select().from(chats).where(where).get();
      return c ? chatRow(c) : null;
    }
    const c = this.db.update(chats).set(set).where(where).returning().get();
    return c ? chatRow(c) : null;
  }

  async claimChat(id: string, token: string, until: string, mode: "start" | "resume") {
    return this.claimChatNow(id, token, until, mode);
  }

  /** claimChat, synchronously (the worker decides on the spot). */
  claimChatNow(id: string, token: string, until: string, mode: "start" | "resume"): ChatRow | null {
    const c =
      mode === "start"
        ? this.db
            .update(chats)
            .set({ status: "running", runToken: token, runUntil: date(until), stop: false, retries: 0 })
            .where(and(eq(chats.id, id), eq(chats.status, "idle")))
            .returning()
            .get()
        : this.db
            .update(chats)
            .set({ runToken: token, runUntil: date(until) })
            .where(
              and(
                eq(chats.id, id),
                eq(chats.status, "running"),
                or(eq(chats.runToken, token), isNull(chats.runUntil), lt(chats.runUntil, new Date())),
              ),
            )
            .returning()
            .get();
    return c ? chatRow(c) : null;
  }

  async queueChatMessage(id: string, entry: Record<string, unknown>) {
    return this.db.transaction(
      (tx) => {
        const c = tx.select({ queue: chats.queue }).from(chats).where(eq(chats.id, id)).get();
        if (!c) return null;
        const queue = [...parse<Record<string, unknown>[]>(c.queue, []), entry];
        const after = tx.update(chats).set({ queue: JSON.stringify(queue) }).where(eq(chats.id, id)).returning().get();
        return after ? chatRow(after) : null;
      },
      { behavior: "immediate" },
    );
  }

  async unqueueChatMessage(id: string, entryId: string) {
    return this.db.transaction(
      (tx) => {
        const c = tx.select({ queue: chats.queue }).from(chats).where(eq(chats.id, id)).get();
        const queue = parse<Record<string, unknown>[]>(c?.queue ?? null, []);
        if (!c || !queue.some((e) => e.id === entryId)) return null;
        const rest = queue.filter((e) => e.id !== entryId);
        const after = tx.update(chats).set({ queue: JSON.stringify(rest) }).where(eq(chats.id, id)).returning().get();
        return after ? chatRow(after) : null;
      },
      { behavior: "immediate" },
    );
  }

  async deleteChat(id: string) {
    // Items and messages go with it (ON DELETE CASCADE).
    this.db.delete(chats).where(eq(chats.id, id)).run();
  }

  async listChatItems(chatId: string, since = 0) {
    return this.db
      .select()
      .from(chatItems)
      .where(and(eq(chatItems.chatId, chatId), gt(chatItems.rev, since)))
      .orderBy(asc(chatItems.seq))
      .all()
      .map((r) => ({ seq: r.seq, rev: r.rev, item: parse<Record<string, unknown>>(r.item, {}) }));
  }

  async putChatItems(chatId: string, items: Omit<ChatItemRow, "rev">[]) {
    // The transaction orders the revisions: whoever has seen revision n has seen every change
    // up to it.
    return this.db.transaction(
      (tx) => {
        const c = tx
          .update(chats)
          .set({ rev: sql`${chats.rev} + 1`, updatedAt: new Date() })
          .where(eq(chats.id, chatId))
          .returning({ rev: chats.rev })
          .get();
        if (!c) return null;
        for (const { seq, item } of items) {
          const value = JSON.stringify(item);
          tx.insert(chatItems)
            .values({ chatId, seq, rev: c.rev, item: value })
            .onConflictDoUpdate({ target: [chatItems.chatId, chatItems.seq], set: { rev: c.rev, item: value } })
            .run();
        }
        return c.rev;
      },
      { behavior: "immediate" },
    );
  }

  async listChatMessages(chatId: string) {
    return this.db
      .select()
      .from(chatMessages)
      .where(eq(chatMessages.chatId, chatId))
      .orderBy(asc(chatMessages.seq))
      .all()
      .map((r) => ({ seq: r.seq, message: parse<Record<string, unknown>>(r.message, {}) }));
  }

  async addChatMessages(chatId: string, rows: ChatMessageRow[]) {
    if (!rows.length) return;
    // A message at a position that is taken fails (the primary key), as in family-planner.
    this.db.transaction((tx) => {
      for (const r of rows) {
        tx.insert(chatMessages).values({ chatId, seq: r.seq, message: JSON.stringify(r.message) }).run();
      }
    });
  }

  // ---- for the worker

  /** Chats the worker can take now (see PendingChat), the oldest first. */
  pendingChats(now = new Date(), limit = 20): PendingChat[] {
    return this.db
      .select({ id: chats.id, status: chats.status, runToken: chats.runToken })
      .from(chats)
      .where(
        or(
          and(eq(chats.status, "running"), or(isNull(chats.runUntil), lt(chats.runUntil, now))),
          and(eq(chats.status, "idle"), sql`${chats.queue} <> '[]'`),
        ),
      )
      .orderBy(asc(chats.updatedAt))
      .limit(limit)
      .all()
      .map((c) => ({ id: c.id, status: c.status === "running" ? "running" : "idle", held: c.runToken !== null }));
  }

  /** Of the given chats: which still exist, and whether the user asked to stop them. */
  chatFlags(ids: string[]): Map<string, { stop: boolean }> {
    if (!ids.length) return new Map();
    const rows = this.db.select({ id: chats.id, stop: chats.stop }).from(chats).where(inArray(chats.id, ids)).all();
    return new Map(rows.map((r) => [r.id, { stop: r.stop }]));
  }
}
