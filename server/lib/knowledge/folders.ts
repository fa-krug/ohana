// The family's knowledge folder: one per family for now, created the first time a device chooses
// one. Its id goes into the folder's marker file (`.ohana-knowledge.json`), so a second device
// recognises the folder; manifests and uploads name it.

import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { kbFolders } from "@/lib/db/schema";
import { HttpError } from "@/lib/api/http";

export type FolderRow = typeof kbFolders.$inferSelect;

export interface KnowledgeFolder {
  id: string;
  createdAt: string;
}

export function folderDto(row: FolderRow): KnowledgeFolder {
  return { id: row.id, createdAt: row.createdAt.toISOString() };
}

export function getFolder(db: Db, familyId: string): FolderRow | null {
  return db.select().from(kbFolders).where(eq(kbFolders.familyId, familyId)).get() ?? null;
}

/** The family's folder, created on first use; `created` says whether this call made it. */
export function ensureFolder(db: Db, familyId: string, userId: string | null, now: Date): { folder: FolderRow; created: boolean } {
  const existing = getFolder(db, familyId);
  if (existing) return { folder: existing, created: false };
  const inserted = db
    .insert(kbFolders)
    .values({ id: randomUUID(), familyId, createdById: userId, createdAt: now })
    .onConflictDoNothing()
    .returning()
    .get();
  // Another request made it in between: that one is the family's.
  return inserted ? { folder: inserted, created: true } : { folder: getFolder(db, familyId)!, created: false };
}

/** The family's folder when `folderId` names it; 404 otherwise (another family's, a deleted one). */
export function requireFolder(db: Db, familyId: string, folderId: unknown): FolderRow {
  const folder = getFolder(db, familyId);
  if (!folder || folder.id !== folderId) throw new HttpError(404, "Folder not found");
  return folder;
}
