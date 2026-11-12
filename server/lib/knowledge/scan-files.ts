// The pictures of the page scans (scans.ts): JPEGs under MEDIA_ROOT/knowledge/<familyId>/, named
// <documentId>_<page>_<ms>.jpg, kept only until the family's AI read them. Never served: only the
// worker reads them. A file goes when its scan is done or failed, when the document's text is
// replaced, with the document, the folder or the family, and by the cleanup (anything older than
// SCAN_KEEP_MS, also files nothing refers to any more).

import { existsSync, readdirSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";
import { lt, type SQL } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { kbPageScans } from "@/lib/db/schema";
import { deleteImageFile, resolveMediaPath, writeMediaFile } from "@/lib/meals/images/storage";

/** The folder under MEDIA_ROOT that holds the scans, by family. */
export const SCAN_DIR = "knowledge";
/** How long a scan (its row and its file) is kept at most. */
export const SCAN_KEEP_MS = 7 * 24 * 60 * 60 * 1000;

/** Writes a page's picture under a name not taken yet; its path relative to the media root. */
export function writeScanFile(familyId: string, documentId: string, page: number, bytes: Buffer, now: Date): string {
  let ms = now.getTime();
  const name = () => `${SCAN_DIR}/${familyId}/${documentId}_${page}_${ms}.jpg`;
  while (existsSync(resolveMediaPath(name())!)) ms++;
  return writeMediaFile(name(), bytes);
}

/** Deletes the scans' files; never throws (a file that's gone is fine). */
export function deleteScanFiles(paths: Iterable<string>): void {
  for (const rel of paths) {
    try {
      deleteImageFile(rel);
    } catch (e) {
      console.warn(`[knowledge] could not delete the page scan ${rel}:`, e);
    }
  }
}

/** Deletes every scan file of a family (once the family is deleted). */
export function deleteFamilyScanFiles(familyId: string): void {
  const dir = resolveMediaPath(`${SCAN_DIR}/${familyId}`);
  if (!dir || dir === resolveMediaPath(SCAN_DIR) || dir === resolveMediaPath(".")) return;
  try {
    rmSync(dir, { recursive: true, force: true });
  } catch (e) {
    console.warn(`[knowledge] could not delete the page scans of family ${familyId}:`, e);
  }
}

/** Db or a transaction of it. */
type Tx = Pick<Db, "select" | "delete">;

/** Deletes the scan rows `where` picks; their files' paths, to delete once the transaction is
 *  through. */
export function takeScans(tx: Tx, where: SQL | undefined): string[] {
  return tx
    .delete(kbPageScans)
    .where(where)
    .returning({ path: kbPageScans.path })
    .all()
    .map((r) => r.path);
}

/** The paths of the scans `where` picks (before something deletes them by a cascade). */
export function scanPaths(tx: Pick<Db, "select">, where: SQL | undefined): string[] {
  return tx
    .select({ path: kbPageScans.path })
    .from(kbPageScans)
    .where(where)
    .all()
    .map((r) => r.path);
}

/** Maintenance: deletes the scans made over SCAN_KEEP_MS ago (rows and files) and any file under
 *  the scans' folder older than that (left by a worker or a request that died). Returns how many
 *  rows went. */
export function pruneScans(db: Db, now: Date): number {
  const before = new Date(now.getTime() - SCAN_KEEP_MS);
  const paths = takeScans(db, lt(kbPageScans.createdAt, before));
  deleteScanFiles(paths);
  const root = resolveMediaPath(SCAN_DIR);
  if (root && existsSync(root)) {
    try {
      for (const family of readdirSync(root, { withFileTypes: true })) {
        if (!family.isDirectory()) continue;
        const dir = join(root, family.name);
        for (const file of readdirSync(dir)) {
          const abs = join(dir, file);
          try {
            if (statSync(abs).mtimeMs < before.getTime()) rmSync(abs, { force: true });
          } catch {
            // gone meanwhile
          }
        }
      }
    } catch (e) {
      console.warn("[knowledge] could not sweep the page scans:", e);
    }
  }
  return paths.length;
}
