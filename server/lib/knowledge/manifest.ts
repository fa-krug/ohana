// A device's manifest of the knowledge folder: every file it sees there (path, size, time, hash,
// tags). The server compares it with its documents and answers the paths whose text it needs, so
// two devices never upload the same file twice. All in one transaction.

import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { kbDocuments } from "@/lib/db/schema";
import { HttpError } from "@/lib/api/http";
import { type DocumentRow, type DocumentStatus, restoredColumns } from "./documents";
import { type FileInfo, cleanFileInfo, nameOf } from "./input";

export const MAX_MANIFEST_FILES = 20_000;

/** The manifest's files, checked; 400 for a bad entry or a path listed twice (after NFC). */
export function cleanManifestFiles(v: unknown): FileInfo[] {
  if (!Array.isArray(v)) throw new HttpError(400, "files must be a list");
  if (v.length > MAX_MANIFEST_FILES) throw new HttpError(413, `Too many files (max. ${MAX_MANIFEST_FILES})`);
  const files = v.map((f) => cleanFileInfo(f));
  const seen = new Set<string>();
  for (const f of files) {
    if (seen.has(f.path)) throw new HttpError(400, `${f.path} is listed twice`);
    seen.add(f.path);
  }
  return files;
}

type Changes = Partial<typeof kbDocuments.$inferInsert>;

/** What the manifest reads of a document: everything it compares and may change, not the text. */
const MANIFEST_COLUMNS = {
  id: kbDocuments.id,
  path: kbDocuments.path,
  name: kbDocuments.name,
  tags: kbDocuments.tags,
  size: kbDocuments.size,
  mtime: kbDocuments.mtime,
  hash: kbDocuments.hash,
  status: kbDocuments.status,
  error: kbDocuments.error,
  indexedAt: kbDocuments.indexedAt,
  missingSince: kbDocuments.missingSince,
  attempts: kbDocuments.attempts,
  runToken: kbDocuments.runToken,
  runUntil: kbDocuments.runUntil,
};
type Row = Pick<DocumentRow, keyof typeof MANIFEST_COLUMNS>;

/** The columns of a document seen again at `path` (its own or, moved, a new one) whose file
 *  is there: tags always, size and time only for the same content (another hash waits for its
 *  upload, so the stored details keep matching the stored text). A missing document goes back to
 *  its status; an excluded one stays excluded, no longer gone. */
function seenAgain(row: Row, f: FileInfo): Changes {
  const changes: Changes = { tags: JSON.stringify(f.tags) };
  if (row.hash === f.hash) Object.assign(changes, { size: f.size, mtime: f.mtime });
  if (row.status === "missing") Object.assign(changes, restoredColumns(row));
  else if (row.missingSince) changes.missingSince = null;
  if (row.path !== f.path) Object.assign(changes, { path: f.path, name: nameOf(f.path) });
  return changes;
}

/** Only the columns that differ from the row's. */
function changed(row: Row, changes: Changes): Changes {
  const out: Changes = {};
  for (const [k, v] of Object.entries(changes) as [keyof Changes, unknown][]) {
    const old = row[k as keyof Row];
    const same = old instanceof Date && v instanceof Date ? old.getTime() === v.getTime() : old === v;
    if (!same) (out as Record<string, unknown>)[k] = v;
  }
  return out;
}

/**
 * Applies a manifest of the folder (the complete list of its files as one device sees them):
 * - a known path with the same hash: tags, size and time updated in place;
 * - a known path with another hash: its text is needed (tags updated);
 * - a new path whose hash is that of a document whose path isn't listed any more: the file was
 *   moved or renamed; the document moves along (chunks and card kept), no upload;
 * - any other new path: its text is needed;
 * - a document whose path isn't listed (and didn't move): missing since now (kept if it was
 *   already missing; an excluded one stays excluded, with `missingSince`).
 * Excluded documents are never asked for. A missing document listed again goes back to ready
 * (indexed), failed or pending. Returns the paths to upload, in the manifest's order.
 *
 * An empty manifest changes nothing: a device whose bookmark went stale or that can't read the
 * folder (iCloud not signed in, the share left) sees no files, and that mustn't mark the whole
 * index missing. Emptying the folder for real leaves the documents as they are until a file
 * appears in it again.
 */
export function applyManifest(db: Db, folderId: string, files: FileInfo[], now: Date): { upload: string[] } {
  if (files.length === 0) return { upload: [] };
  // Immediate: the rows are read, then written; under WAL a deferred transaction whose snapshot
  // the worker wrote past in between fails with SQLITE_BUSY_SNAPSHOT.
  return db.transaction(
    (tx) => {
      const rows = tx.select(MANIFEST_COLUMNS).from(kbDocuments).where(eq(kbDocuments.folderId, folderId)).all();
      const byPath = new Map(rows.map((r) => [r.path, r]));
      const listed = new Set(files.map((f) => f.path));
      // Documents whose path is gone, by hash: where a new path may have moved them.
      const movable = new Map<string, Row[]>();
      for (const r of rows) {
        if (listed.has(r.path)) continue;
        movable.set(r.hash, [...(movable.get(r.hash) ?? []), r]);
      }
      const moved = new Set<string>();
      const upload: string[] = [];
      const save = (row: Row, changes: Changes) => {
        const diff = changed(row, changes);
        if (Object.keys(diff).length === 0) return;
        tx.update(kbDocuments)
          .set({ ...diff, updatedAt: now })
          .where(eq(kbDocuments.id, row.id))
          .run();
      };

      for (const f of files) {
        const row = byPath.get(f.path);
        if (row) {
          save(row, seenAgain(row, f));
          if (row.hash !== f.hash && row.status !== "excluded") upload.push(f.path);
          continue;
        }
        const from = movable.get(f.hash)?.shift();
        if (from) {
          moved.add(from.id);
          save(from, seenAgain(from, f));
          continue;
        }
        upload.push(f.path);
      }

      for (const r of rows) {
        if (listed.has(r.path) || moved.has(r.id)) continue;
        const status = r.status as DocumentStatus;
        if (status === "excluded") save(r, { missingSince: r.missingSince ?? now });
        else if (status !== "missing") save(r, { status: "missing", missingSince: now, runToken: null, runUntil: null });
      }
      return { upload };
    },
    { behavior: "immediate" },
  );
}
