// The family's knowledge folder: one per family for now, created the first time a device chooses
// one. Its id goes into the folder's marker file (`.ohana-knowledge.json`), so a second device
// recognises the folder; manifests and uploads name it. Choosing another folder replaces it (a new
// id, the old documents gone).

import { randomUUID } from "node:crypto";
import { and, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { kbFolders, kbPageScans } from "@/lib/db/schema";
import { HttpError } from "@/lib/api/http";
import { deleteScanFiles, scanPaths, takeScans } from "./scan-files";

export type FolderRow = typeof kbFolders.$inferSelect;

export interface KnowledgeFolder {
  id: string;
  createdAt: string;
  /** The last non-empty manifest (any device's) and the name the device gave; null before one. */
  lastManifestAt: string | null;
  lastManifestDevice: string | null;
  /** Whether the app sends pages its own OCR read poorly to the family's AI (scans.ts). */
  aiScans: boolean;
}

export function folderDto(row: FolderRow): KnowledgeFolder {
  return {
    id: row.id,
    createdAt: row.createdAt.toISOString(),
    lastManifestAt: row.lastManifestAt?.toISOString() ?? null,
    lastManifestDevice: row.lastManifestDevice ?? null,
    aiScans: row.aiScans,
  };
}

export function getFolder(db: Pick<Db, "select">, familyId: string): FolderRow | null {
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

/** A new folder for the family in place of the old one (the device chose another folder): the
 *  old folder goes with its documents, their chunks (and FTS rows, by the triggers) and cards;
 *  its id answers 404 from then on. */
export function replaceFolder(db: Db, familyId: string, userId: string | null, now: Date): FolderRow {
  let paths: string[] = [];
  const folder = db.transaction(
    (tx) => {
      // The page scans go with the documents (cascade); their files after. The setting stays.
      paths = scanPaths(tx, eq(kbPageScans.familyId, familyId));
      const aiScans = getFolder(tx, familyId)?.aiScans ?? false;
      tx.delete(kbFolders).where(eq(kbFolders.familyId, familyId)).run();
      return tx.insert(kbFolders).values({ id: randomUUID(), familyId, createdById: userId, createdAt: now, aiScans }).returning().get();
    },
    { behavior: "immediate" },
  );
  deleteScanFiles(paths);
  return folder;
}

/** Turns the family's AI reading of poor scans on or off (PATCH /knowledge/folder); 404 without
 *  a folder. Off, the scans the app sent on its own and still waiting go (rows and files); those
 *  an editor asked for (forced) and those being read stay. */
export function setAiScans(db: Db, familyId: string, on: boolean): FolderRow {
  let paths: string[] = [];
  const folder = db.transaction(
    (tx) => {
      const row = tx.update(kbFolders).set({ aiScans: on }).where(eq(kbFolders.familyId, familyId)).returning().get();
      if (!row) throw new HttpError(404, "Folder not found");
      if (!on) {
        paths = takeScans(
          tx,
          and(eq(kbPageScans.familyId, familyId), eq(kbPageScans.status, "waiting"), eq(kbPageScans.forced, false)),
        );
      }
      return row;
    },
    { behavior: "immediate" },
  );
  deleteScanFiles(paths);
  return folder;
}

/** The family's folder when `folderId` names it; 404 otherwise (another family's, a deleted one). */
export function requireFolder(db: Db, familyId: string, folderId: unknown): FolderRow {
  const folder = getFolder(db, familyId);
  if (!folder || folder.id !== folderId) throw new HttpError(404, "Folder not found");
  return folder;
}
