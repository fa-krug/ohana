// The pages of knowledge documents the app sent for view_knowledge_pages (tools/knowledge-pages.ts):
// JPEGs under MEDIA_ROOT/assistant/<familyId>/<chatId>/, named <call>_<page>.jpg (<call>: a hash of
// the tool call's id). The chat's messages refer to them as "media:<path>" image parts, so the
// database keeps no image data; the worker reads them into data URLs only for the model's request
// (`withPageImages`). Never served. They go with their chat: when it is deleted (by the user,
// the family's chat limit) and by the cleanup (`pruneChatFiles`: folders of chats that are
// gone, after the family or the user was deleted).

import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { inArray } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { chats } from "@/lib/db/schema";
import { resolveMediaPath, writeMediaFile } from "@/lib/meals/images/storage";
import type { ChatMessage, ContentPart } from "./provider";

/** The folder under MEDIA_ROOT that holds the pages, by family and chat. */
export const PAGES_DIR = "assistant";
/** How an image part names a page file (its path relative to the media root). */
export const MEDIA_URL = "media:";
/** The first text of the message that carries the pages (`isPagesMessage`). */
export const PAGES_HEAD = "[Pages for view_knowledge_pages";
/** What the model gets for a page whose file is gone. */
const GONE = "(a page image that is no longer kept)";

/** Ids as they are in paths: the chats' UUIDs, the families' ids. */
const SAFE = /^[A-Za-z0-9_-]{1,100}$/;

function chatDir(familyId: string, chatId: string): string {
  if (!SAFE.test(familyId) || !SAFE.test(chatId)) throw new Error("Unexpected id in a page path");
  return `${PAGES_DIR}/${familyId}/${chatId}`;
}

/** The path (relative to the media root) of a page the app sent for the tool call `callId`. */
export function pageFilePath(familyId: string, chatId: string, callId: string, page: number): string {
  const call = createHash("sha256").update(callId).digest("hex").slice(0, 16);
  return `${chatDir(familyId, chatId)}/${call}_${page}.jpg`;
}

/** Writes a page's JPEG (replacing one sent before for the same call and page); its path. */
export function writePageFile(familyId: string, chatId: string, callId: string, page: number, jpeg: Buffer): string {
  return writeMediaFile(pageFilePath(familyId, chatId, callId, page), jpeg);
}

/** Whether the page was sent (its file is there). */
export function pageFileExists(rel: string): boolean {
  const abs = resolveMediaPath(rel);
  return !!abs && existsSync(abs);
}

/** The image part a message keeps for a page file. */
export const pagePart = (rel: string): ContentPart => ({ type: "image_url", image_url: { url: MEDIA_URL + rel } });

/** The message that carries the pages (a message of the user: tool results can't hold images). */
export function isPagesMessage(m: Pick<ChatMessage, "role" | "content">): boolean {
  if (m.role !== "user" || !Array.isArray(m.content)) return false;
  const first = m.content[0];
  return first?.type === "text" && first.text.startsWith(PAGES_HEAD);
}

/** The messages as the model's endpoint gets them: each page file read into a data URL (one that
 *  is gone becomes a short text). Messages without page files are passed on as they are. */
export function withPageImages(messages: ChatMessage[]): ChatMessage[] {
  return messages.map((m) => {
    if (!Array.isArray(m.content) || !m.content.some((p) => p.type === "image_url" && p.image_url.url.startsWith(MEDIA_URL))) {
      return m;
    }
    return {
      ...m,
      content: m.content.map((p): ContentPart => {
        if (p.type !== "image_url" || !p.image_url.url.startsWith(MEDIA_URL)) return p;
        const abs = resolveMediaPath(p.image_url.url.slice(MEDIA_URL.length));
        try {
          if (abs?.startsWith(resolveMediaPath(PAGES_DIR)! + "/")) {
            return { type: "image_url", image_url: { url: `data:image/jpeg;base64,${readFileSync(abs).toString("base64")}` } };
          }
        } catch {
          // gone: told below
        }
        return { type: "text", text: GONE };
      }),
    };
  });
}

/** Deletes a chat's page files; never throws. */
export function deleteChatFiles(familyId: string, chatId: string): void {
  try {
    const dir = resolveMediaPath(chatDir(familyId, chatId));
    if (dir) rmSync(dir, { recursive: true, force: true });
  } catch (e) {
    console.warn(`[assistant] could not delete the page images of chat ${chatId}:`, e);
  }
}

/** Maintenance: deletes the page folders of chats that no longer exist (and family folders left
 *  empty). Returns how many chat folders went. */
export function pruneChatFiles(db: Db): number {
  const root = resolveMediaPath(PAGES_DIR);
  if (!root || !existsSync(root)) return 0;
  let removed = 0;
  for (const family of safeList(root)) {
    const familyDir = join(root, family);
    const ids = safeList(familyDir);
    const known = new Set(
      ids.length
        ? db.select({ id: chats.id }).from(chats).where(inArray(chats.id, ids)).all().map((r) => r.id)
        : [],
    );
    for (const id of ids) {
      if (known.has(id)) continue;
      rmSync(join(familyDir, id), { recursive: true, force: true });
      removed++;
    }
    if (!safeList(familyDir).length) rmSync(familyDir, { recursive: true, force: true });
  }
  return removed;
}

function safeList(dir: string): string[] {
  try {
    return readdirSync(dir).filter((n) => SAFE.test(n));
  } catch {
    return [];
  }
}
