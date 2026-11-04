// The documents of the family's knowledge folder: one row per file (by its path in the folder),
// with the text the app read from it, the chunks the worker made of that text and the card. The
// file itself never reaches the server.
//
// Status, and what keeps it straight (the manifest relies on it to bring a document back):
// - pending: text waiting for the worker (`indexedAt` and `error` null); searchable by the chunks
//   it still has after a reindex (a new upload deletes them, so new text has none yet);
// - ready: chunked (`indexedAt` set);
// - failed: the worker gave up (`error` set, `indexedAt` null);
// - missing: its path is no longer in the folder, since `missingSince` (chunks and card kept;
//   back to one of the above when the file is listed again, deleted after 30 days);
// - excluded: kept out of the index by an editor (no chunks); stays excluded when its file is
//   gone (`missingSince` set) and comes back, and is deleted 30 days after it went.

import { randomUUID } from "node:crypto";
import { and, desc, eq, inArray, isNotNull, lt, ne, or, sql, type SQL } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { kbChunks, kbDocuments } from "@/lib/db/schema";
import { HttpError } from "@/lib/api/http";
import { familyNames } from "@/lib/families/people";
import { type FileInfo, nameOf } from "./input";

export type DocumentRow = typeof kbDocuments.$inferSelect;

export const STATUSES = ["pending", "ready", "failed", "missing", "excluded"] as const;
export type DocumentStatus = (typeof STATUSES)[number];

/** The card's state (card.ts): pending (waiting for the worker, or for the family's AI to be set
 *  up), ready, failed (`cardError`), none (the document has no text to make one of). */
export const CARD_STATUSES = ["pending", "ready", "failed", "none"] as const;
export type CardStatus = (typeof CARD_STATUSES)[number];

/** A fact of a card: a short statement and the verbatim quote it rests on, found in the chunk
 *  `chunkId` (on `page`). */
export interface KnowledgeFact {
  text: string;
  quote: string;
  chunkId: number;
  page: number;
}

/** How long a document whose file is gone is kept (a file put back in time keeps its card). */
export const MISSING_KEEP_MS = 30 * 24 * 60 * 60 * 1000;

/** Most text an upload may carry (UTF-8 bytes of all its pages), and most pages. */
export const MAX_TEXT_BYTES = 2_000_000;
export const MAX_PAGES = 2000;

export interface KnowledgePerson {
  id: string;
  name: string;
  account: boolean;
}

/** A document in a list (no text, no chunks). */
export interface KnowledgeDocumentSummary {
  id: string;
  folderId: string;
  path: string;
  name: string;
  tags: string[];
  size: number;
  /** The file's modification time, ms since 1970. */
  mtime: number;
  hash: string;
  pages: number;
  status: DocumentStatus;
  error: string | null;
  cardStatus: CardStatus;
  /** Why the card failed (with `cardStatus` failed). */
  cardError: string | null;
  summary: string | null;
  docDate: string | null;
  /** Whose it is (the card's), while they are in the family. */
  person: KnowledgePerson | null;
  indexedAt: string | null;
  missingSince: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface KnowledgeChunk {
  id: number;
  seq: number;
  page: number;
  text: string;
}

/** A document with its card's facts and its chunks. */
export interface KnowledgeDocument extends KnowledgeDocumentSummary {
  facts: KnowledgeFact[] | null;
  chunks: KnowledgeChunk[];
}

/** The status a document goes back to when its file is listed again (see the top). */
export function restoredStatus(row: Pick<DocumentRow, "indexedAt" | "error">): DocumentStatus {
  return row.indexedAt ? "ready" : row.error ? "failed" : "pending";
}

/** The columns of a missing document whose file is there again: its status back, no longer
 *  gone, and a fresh count of runs when it waits for the worker again. */
export function restoredColumns(row: Pick<DocumentRow, "indexedAt" | "error">) {
  const status = restoredStatus(row);
  return { status, missingSince: null, ...(status === "pending" ? { attempts: 0 } : {}) };
}

/** Whether pages hold any text (not just whitespace). */
export function hasText(pages: readonly unknown[] | null): boolean {
  return (pages ?? []).some((p) => typeof p === "string" && p.trim() !== "");
}

export function parseJsonArray<T = unknown>(raw: string | null): T[] | null {
  if (raw === null) return null;
  try {
    const v = JSON.parse(raw);
    return Array.isArray(v) ? v : null;
  } catch {
    return null;
  }
}

type People = Map<string, KnowledgePerson>;

function peopleOf(db: Db, familyId: string): People {
  return new Map(familyNames(db, familyId).map(({ id, name, account }) => [id, { id, name, account }]));
}

function summaryDto(row: DocumentRow, people: People): KnowledgeDocumentSummary {
  const personId = row.personUserId ?? row.personPersonId;
  return {
    id: row.id,
    folderId: row.folderId,
    path: row.path,
    name: row.name,
    tags: parseJsonArray<string>(row.tags) ?? [],
    size: row.size,
    mtime: row.mtime,
    hash: row.hash,
    pages: row.pages,
    status: row.status as DocumentStatus,
    error: row.error,
    cardStatus: (CARD_STATUSES as readonly string[]).includes(row.cardStatus) ? (row.cardStatus as CardStatus) : "pending",
    cardError: row.cardStatus === "failed" ? row.cardError : null,
    summary: row.summary,
    docDate: row.docDate,
    person: (personId && people.get(personId)) || null,
    indexedAt: row.indexedAt?.toISOString() ?? null,
    missingSince: row.missingSince?.toISOString() ?? null,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

export function getDocumentRow(db: Pick<Db, "select">, familyId: string, id: string): DocumentRow | null {
  return (
    db
      .select()
      .from(kbDocuments)
      .where(and(eq(kbDocuments.familyId, familyId), eq(kbDocuments.id, id)))
      .get() ?? null
  );
}

function requireDocument(db: Pick<Db, "select">, familyId: string, id: string): DocumentRow {
  const row = getDocumentRow(db, familyId, id);
  if (!row) throw new HttpError(404, "Document not found");
  return row;
}

export function getDocument(db: Db, familyId: string, id: string): KnowledgeDocument {
  const row = requireDocument(db, familyId, id);
  const chunks = db
    .select({ id: kbChunks.id, seq: kbChunks.seq, page: kbChunks.page, text: kbChunks.text })
    .from(kbChunks)
    .where(eq(kbChunks.documentId, id))
    .orderBy(kbChunks.seq)
    .all();
  return { ...summaryDto(row, peopleOf(db, familyId)), facts: parseJsonArray<KnowledgeFact>(row.facts), chunks };
}

// ---- the list ----

export interface ListOptions {
  /** Name, path or tags contain it (LIKE: case ignored for ASCII only). */
  q?: string | null;
  tag?: string | null;
  /** A subfolder: its documents and those of its subfolders. */
  folder?: string | null;
  /** Whose it is (the card's person): a member's id, an account's or a person's. */
  person?: string | null;
  /** One status; without one everything but the excluded. */
  status?: DocumentStatus | null;
  cursor?: string | null;
  limit?: number;
}

export const DEFAULT_LIMIT = 50;
export const MAX_LIMIT = 200;

/** `%` and `_` (and the escape itself) match themselves in a LIKE … ESCAPE '\' pattern. */
export function likeEscape(s: string): string {
  return s.replace(/[\\%_]/g, (c) => `\\${c}`);
}

/** The documents under `folder` (a path prefix at a "/"). */
export function inFolder(folder: string): SQL {
  return sql`${kbDocuments.path} like ${`${likeEscape(folder)}/%`} escape '\\'`;
}

/** Documents carrying `tag` among their tags. */
export function hasTag(tag: string): SQL {
  return sql`exists (select 1 from json_each(${kbDocuments.tags}) where json_each.value = ${tag})`;
}

/** The position after a list's last document: its mtime and id. */
function encodeCursor(row: Pick<DocumentRow, "mtime" | "id">): string {
  return Buffer.from(JSON.stringify([row.mtime, row.id])).toString("base64url");
}

function decodeCursor(raw: string): { mtime: number; id: string } {
  try {
    const [mtime, id] = JSON.parse(Buffer.from(raw, "base64url").toString("utf8"));
    if (Number.isSafeInteger(mtime) && typeof id === "string") return { mtime, id };
  } catch {
    // fall through
  }
  throw new HttpError(400, "cursor is not valid");
}

/** Newest first (the file's modification time, then id), `limit` at a time. */
export function listDocuments(
  db: Db,
  familyId: string,
  opts: ListOptions = {},
): { documents: KnowledgeDocumentSummary[]; nextCursor: string | null } {
  const limit = Math.min(Math.max(opts.limit ?? DEFAULT_LIMIT, 1), MAX_LIMIT);
  const where: (SQL | undefined)[] = [
    eq(kbDocuments.familyId, familyId),
    opts.status ? eq(kbDocuments.status, opts.status) : ne(kbDocuments.status, "excluded"),
  ];
  const q = opts.q?.normalize("NFC").trim();
  if (q) {
    const pattern = `%${likeEscape(q)}%`;
    where.push(
      sql`(${kbDocuments.name} like ${pattern} escape '\\' or ${kbDocuments.path} like ${pattern} escape '\\' or ${kbDocuments.tags} like ${pattern} escape '\\')`,
    );
  }
  if (opts.tag) where.push(hasTag(opts.tag.normalize("NFC")));
  if (opts.folder) where.push(inFolder(opts.folder));
  if (opts.person) where.push(or(eq(kbDocuments.personUserId, opts.person), eq(kbDocuments.personPersonId, opts.person)));
  if (opts.cursor) {
    const c = decodeCursor(opts.cursor);
    where.push(or(lt(kbDocuments.mtime, c.mtime), and(eq(kbDocuments.mtime, c.mtime), lt(kbDocuments.id, c.id))));
  }
  const rows = db
    .select()
    .from(kbDocuments)
    .where(and(...where))
    .orderBy(desc(kbDocuments.mtime), desc(kbDocuments.id))
    .limit(limit + 1)
    .all();
  const page = rows.slice(0, limit);
  const people = peopleOf(db, familyId);
  return {
    documents: page.map((r) => summaryDto(r, people)),
    nextCursor: rows.length > limit ? encodeCursor(page[page.length - 1]) : null,
  };
}

/** The tags of the documents that aren't excluded, with how many carry each; most used first. */
export function listTags(db: Db, familyId: string): { tag: string; count: number }[] {
  return db.all<{ tag: string; count: number }>(sql`
    select json_each.value as tag, count(*) as count
    from ${kbDocuments}, json_each(${kbDocuments.tags})
    where ${kbDocuments.familyId} = ${familyId} and ${kbDocuments.status} != 'excluded'
    group by json_each.value
    order by count desc, tag`);
}

/** How many of the family's documents have each status, and how many chunks the index holds. */
export function countDocuments(db: Db, familyId: string): { counts: Record<DocumentStatus, number>; chunks: number } {
  const counts = Object.fromEntries(STATUSES.map((s) => [s, 0])) as Record<DocumentStatus, number>;
  const rows = db
    .select({ status: kbDocuments.status, n: sql<number>`count(*)` })
    .from(kbDocuments)
    .where(eq(kbDocuments.familyId, familyId))
    .groupBy(kbDocuments.status)
    .all();
  for (const { status, n } of rows) if (status in counts) counts[status as DocumentStatus] = n;
  const chunks = db.select({ n: sql<number>`count(*)` }).from(kbChunks).where(eq(kbChunks.familyId, familyId)).get()?.n ?? 0;
  return { counts, chunks };
}

// ---- changes ----

/** What an upload carries: the file's details and its text by page. */
export interface UploadInput extends FileInfo {
  pages: string[];
}

/** Pages of text: a list of strings, NFC, at most MAX_PAGES and MAX_TEXT_BYTES in all (413). */
export function cleanPages(v: unknown): string[] {
  if (!Array.isArray(v) || v.some((p) => typeof p !== "string")) {
    throw new HttpError(400, "pages must be a list of strings");
  }
  if (v.length > MAX_PAGES) throw new HttpError(413, `Too many pages (max. ${MAX_PAGES})`);
  const pages = (v as string[]).map((p) => p.normalize("NFC"));
  const bytes = pages.reduce((n, p) => n + Buffer.byteLength(p, "utf8"), 0);
  if (bytes > MAX_TEXT_BYTES) throw new HttpError(413, `The text is too long (max. ${MAX_TEXT_BYTES / 1_000_000} MB)`);
  return pages;
}

/** Db or a transaction of it. */
export type Tx = Pick<Db, "insert" | "update" | "delete" | "select">;

export function deleteChunks(db: Tx, documentId: string): void {
  db.delete(kbChunks).where(eq(kbChunks.documentId, documentId)).run();
}

/** A card made again: none yet, waiting for the worker (card-runner.ts), without its lease. */
export const CARD_RESET = {
  summary: null,
  facts: null,
  docDate: null,
  personUserId: null,
  personPersonId: null,
  cardStatus: "pending",
  cardRunToken: null,
  cardRunUntil: null,
  cardAttempts: 0,
  cardRetries: 0,
  cardError: null,
} as const;

/** What a document's columns become with new text: waiting for the worker, without the old
 *  text's error, card and lease. */
function freshText(input: UploadInput) {
  return {
    hash: input.hash,
    size: input.size,
    mtime: input.mtime,
    tags: JSON.stringify(input.tags),
    pages: input.pages.length,
    text: JSON.stringify(input.pages),
    error: null,
    ...CARD_RESET,
    indexedAt: null,
    runToken: null,
    runUntil: null,
    attempts: 0,
  };
}

/**
 * Stores the text the app read from a file (PUT /knowledge/documents), by folder + path.
 * The same file again (same hash) changes nothing but its tags, size and time while it is
 * pending, ready or excluded: an upload is idempotent. A missing one is back (its status as it
 * was, see the top). New text (another hash, a failed document, or text for a document stored
 * without any: a device that reads more than the one before) replaces the old: the chunks go at
 * once (a changed file must not be found by its old words), the card too, and the document waits
 * for the worker. An excluded document keeps its status (its new text is there for when it is
 * let back in).
 */
export function uploadDocument(
  db: Db,
  familyId: string,
  folderId: string,
  input: UploadInput,
  now: Date,
): { id: string; status: DocumentStatus; created: boolean } {
  // Immediate: read, then written (see applyManifest).
  return db.transaction(
    (tx) => {
      const row = tx
        .select()
        .from(kbDocuments)
        .where(and(eq(kbDocuments.folderId, folderId), eq(kbDocuments.path, input.path)))
        .get();
      if (!row) {
        const id = randomUUID();
        tx.insert(kbDocuments)
          .values({ id, familyId, folderId, path: input.path, name: nameOf(input.path), ...freshText(input), status: "pending", createdAt: now, updatedAt: now })
          .run();
        return { id, status: "pending" as const, created: true };
      }
      const status = row.status as DocumentStatus;
      const moreText = hasText(input.pages) && !hasText(parseJsonArray(row.text));
      if (row.hash === input.hash && !moreText && status !== "failed") {
        const restored = status === "missing" ? restoredColumns(row) : { missingSince: null };
        tx.update(kbDocuments)
          .set({ tags: JSON.stringify(input.tags), size: input.size, mtime: input.mtime, ...restored, updatedAt: now })
          .where(eq(kbDocuments.id, row.id))
          .run();
        return { id: row.id, status: "status" in restored ? restored.status : status, created: false };
      }
      const next: DocumentStatus = status === "excluded" ? "excluded" : "pending";
      deleteChunks(tx, row.id);
      tx.update(kbDocuments)
        .set({ ...freshText(input), status: next, missingSince: null, updatedAt: now })
        .where(eq(kbDocuments.id, row.id))
        .run();
      return { id: row.id, status: next, created: false };
    },
    { behavior: "immediate" },
  );
}

/** Asks the worker to read the document's text again. Its chunks stay until it has, and so it
 *  stays searchable meanwhile (the search takes pending documents' chunks too); the card is made
 *  again after it. */
export function reindexDocument(db: Db, familyId: string, id: string, now: Date): KnowledgeDocumentSummary {
  db.transaction(
    (tx) => {
      const row = requireDocument(tx, familyId, id);
      if (row.status === "excluded") throw new HttpError(409, "The document is excluded");
      if (row.status === "missing") throw new HttpError(409, "The document's file is missing");
      tx.update(kbDocuments)
        .set({ status: "pending", error: null, indexedAt: null, runToken: null, runUntil: null, attempts: 0, ...CARD_RESET, updatedAt: now })
        .where(eq(kbDocuments.id, id))
        .run();
    },
    { behavior: "immediate" },
  );
  return summaryDto(requireDocument(db, familyId, id), peopleOf(db, familyId));
}

/** Keeps a document out of the index (its chunks go) or lets it back in: pending (the worker
 *  reads its stored text again, then makes a new card), or missing while its file is gone. */
export function setExcluded(db: Db, familyId: string, id: string, excluded: boolean, now: Date): KnowledgeDocumentSummary {
  db.transaction(
    (tx) => {
      const row = requireDocument(tx, familyId, id);
      const isExcluded = row.status === "excluded";
      if (excluded && !isExcluded) {
        deleteChunks(tx, id);
        tx.update(kbDocuments)
          .set({ status: "excluded", error: null, indexedAt: null, runToken: null, runUntil: null, cardRunToken: null, cardRunUntil: null, updatedAt: now })
          .where(eq(kbDocuments.id, id))
          .run();
      } else if (!excluded && isExcluded) {
        tx.update(kbDocuments)
          .set({ status: row.missingSince ? "missing" : "pending", attempts: 0, ...CARD_RESET, updatedAt: now })
          .where(eq(kbDocuments.id, id))
          .run();
      }
    },
    { behavior: "immediate" },
  );
  return summaryDto(requireDocument(db, familyId, id), peopleOf(db, familyId));
}

/** Makes a ready document's card again (POST …/{id}/card): emptied, waiting for the worker.
 *  409 for a document that isn't ready or has no text. */
export function remakeCard(db: Db, familyId: string, id: string, now: Date): KnowledgeDocumentSummary {
  db.transaction(
    (tx) => {
      const row = requireDocument(tx, familyId, id);
      if (row.status !== "ready") throw new HttpError(409, "The document isn't ready");
      const chunk = tx.select({ id: kbChunks.id }).from(kbChunks).where(eq(kbChunks.documentId, id)).limit(1).get();
      if (!chunk) throw new HttpError(409, "The document has no text");
      tx.update(kbDocuments).set({ ...CARD_RESET, updatedAt: now }).where(eq(kbDocuments.id, id)).run();
    },
    { behavior: "immediate" },
  );
  return summaryDto(requireDocument(db, familyId, id), peopleOf(db, familyId));
}

/** The family's failed cards wait for the worker again (its AI settings changed: maybe fixed). */
export function retryFailedCards(db: Pick<Db, "update">, familyId: string): number {
  return db
    .update(kbDocuments)
    .set({ cardStatus: "pending", cardError: null, cardAttempts: 0, cardRetries: 0, cardRunToken: null, cardRunUntil: null })
    .where(and(eq(kbDocuments.familyId, familyId), eq(kbDocuments.cardStatus, "failed")))
    .run().changes;
}

/** Deletes the documents whose file has been gone for MISSING_KEEP_MS (maintenance). */
export function pruneMissingDocuments(db: Db, now: Date): number {
  const before = new Date(now.getTime() - MISSING_KEEP_MS);
  return db
    .delete(kbDocuments)
    .where(
      and(
        inArray(kbDocuments.status, ["missing", "excluded"]),
        isNotNull(kbDocuments.missingSince),
        lt(kbDocuments.missingSince, before),
      ),
    )
    .run().changes;
}
