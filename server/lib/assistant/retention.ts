// How many assistant chats each member keeps in a family: `ai_settings.chat_limit` (Settings →
// Assistant → Chat history, PUT /ai/settings `chatLimit`; DEFAULT_CHAT_LIMIT, 50, without a
// setting). Each member's newest chats (by their last message or answer) stay; the older ones go,
// with their items, messages and page images, when the member starts a new chat (chat-routes.ts)
// and for every member at once when the family lowers the limit. A running chat is never deleted.

import { and, desc, eq, inArray } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { aiSettings, chats } from "@/lib/db/schema";
import { deleteChatFiles } from "./page-images";
import { DEFAULT_CHAT_LIMIT } from "./store";

/** The family's chat limit. */
export function chatLimitOf(db: Db, familyId: string): number {
  return (
    db.select({ limit: aiSettings.chatLimit }).from(aiSettings).where(eq(aiSettings.familyId, familyId)).get()?.limit ??
    DEFAULT_CHAT_LIMIT
  );
}

/** Deletes the chats beyond the newest `limit` of each member of the family (of `userId` only, when
 *  given); how many went. */
export function trimChats(db: Db, familyId: string, limit: number, userId?: string): number {
  const rows = db
    .select({ id: chats.id, userId: chats.userId, status: chats.status })
    .from(chats)
    .where(userId ? and(eq(chats.familyId, familyId), eq(chats.userId, userId)) : eq(chats.familyId, familyId))
    .orderBy(desc(chats.updatedAt), desc(chats.createdAt))
    .all();
  const kept = new Map<string, number>();
  const old: string[] = [];
  for (const r of rows) {
    const n = (kept.get(r.userId) ?? 0) + 1;
    kept.set(r.userId, n);
    if (n > limit && r.status !== "running") old.push(r.id);
  }
  for (let i = 0; i < old.length; i += 500) {
    db.delete(chats).where(inArray(chats.id, old.slice(i, i + 500))).run();
  }
  for (const id of old) deleteChatFiles(familyId, id);
  return old.length;
}
