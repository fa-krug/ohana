// How long a family keeps its assistant chats: `ai_settings.chat_max_age_days` (Settings →
// Assistant, PUT /ai/settings `chatMaxAgeDays`; 0 keeps them). The worker's cleanup deletes the
// chats nobody touched for longer (their last message or answer: `updated_at`), with their items,
// messages and page images. A running chat stays until its turn is over.

import { and, eq, gt, inArray, lt, sql } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { aiSettings, chats } from "@/lib/db/schema";
import { deleteChatFiles } from "./page-images";

const DAY_MS = 24 * 60 * 60 * 1000;

/** Deletes the chats older than their family's max age; how many went. */
export function pruneOldChats(db: Db, now: Date): number {
  const old = db
    .select({ id: chats.id, familyId: chats.familyId })
    .from(chats)
    .innerJoin(aiSettings, eq(aiSettings.familyId, chats.familyId))
    .where(
      and(
        gt(aiSettings.chatMaxAgeDays, 0),
        eq(chats.status, "idle"),
        lt(chats.updatedAt, sql`${now.getTime()} - ${aiSettings.chatMaxAgeDays} * ${DAY_MS}`),
      ),
    )
    .all();
  if (!old.length) return 0;
  for (let i = 0; i < old.length; i += 500) {
    db.delete(chats).where(inArray(chats.id, old.slice(i, i + 500).map((c) => c.id))).run();
  }
  for (const c of old) deleteChatFiles(c.familyId, c.id);
  return old.length;
}
