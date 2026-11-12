import { index, integer, primaryKey, sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core";
import { families, familyPeople, users } from "../schema";

// ---- the knowledge base (phase 12) ----
// A derived index of the family's paperwork folder (an iCloud Drive folder the app reads): the
// server never holds a file, only its path, metadata, text by page, chunks and a card. Reading
// the folder again rebuilds all of it. `kb_chunks_fts` (FTS5, external content over
// `kb_chunks`, kept in step by triggers) is hand-written SQL in the migration 0025_knowledge.

/** The family's knowledge folder (one per family for now): the id the app writes into the
 *  folder's marker file so a second device recognises it. `lastManifestAt` / `lastManifestDevice`:
 *  the last non-empty manifest and the device that sent it (the app's settings show them).
 *  `aiScans`: whether the app sends pages its own OCR read poorly to the family's AI
 *  (lib/knowledge/scans.ts); off by default, as it sends the family's papers to the AI provider. */
export const kbFolders = sqliteTable(
  "kb_folders",
  {
    id: text("id").primaryKey(),
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    createdById: text("created_by_id").references(() => users.id, { onDelete: "set null" }),
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
    lastManifestAt: integer("last_manifest_at", { mode: "timestamp_ms" }),
    lastManifestDevice: text("last_manifest_device"),
    aiScans: integer("ai_scans", { mode: "boolean" }).notNull().default(false),
  },
  (t) => ({ kbFoldersFamilyUniq: uniqueIndex("kb_folders_family_uniq").on(t.familyId) }),
);

/** A file of the folder, by its path relative to the folder (NFC, "/" separated). `status`:
 *  pending (text waiting for the worker) | ready (chunked, `indexedAt` set) | failed (`error`) |
 *  missing (the path is no longer in the folder, since `missingSince`; deleted after 30 days) |
 *  excluded (kept out of the index; `missingSince` set while its file is gone). `text` is the
 *  uploaded text, a JSON array of pages, kept so the worker can chunk it again. The card
 *  (`summary`, `facts`, `docDate`, whose it is; `cardStatus`) comes from the worker. `runToken` /
 *  `runUntil` are the worker's lease (lib/knowledge/runner.ts): every change of the text or the
 *  status clears it, so a run that lost it writes nothing. */
export const kbDocuments = sqliteTable(
  "kb_documents",
  {
    id: text("id").primaryKey(),
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    folderId: text("folder_id")
      .notNull()
      .references(() => kbFolders.id, { onDelete: "cascade" }),
    path: text("path").notNull(),
    /** The path's last part. */
    name: text("name").notNull(),
    /** JSON array of the file's Finder tags. */
    tags: text("tags").notNull().default("[]"),
    size: integer("size").notNull().default(0),
    /** The file's modification time, ms since 1970. */
    mtime: integer("mtime").notNull().default(0),
    /** SHA-256 of the file, lowercase hex. */
    hash: text("hash").notNull(),
    /** Number of pages of `text`. */
    pages: integer("pages").notNull().default(0),
    /** JSON array of page texts. */
    text: text("text").notNull().default("[]"),
    /** The version of the app's reader the text came from (newer readers read scans better: the
     *  manifest asks again for documents an older one read). */
    reader: integer("reader").notNull().default(1),
    /** JSON array of the page numbers whose text the family's AI transcribed from a page scan
     *  (lib/knowledge/scan-runner.ts); emptied whenever the text is replaced. */
    aiPages: text("ai_pages").notNull().default("[]"),
    /** Whether a device judged the file's pages (the scans its OCR read poorly go to the family's
     *  AI) while the family's AI scans were on; the manifest asks once more for PDFs / images
     *  without it while they are (manifest.ts). */
    scansChecked: integer("scans_checked", { mode: "boolean" }).notNull().default(false),
    status: text("status").notNull().default("pending"),
    error: text("error"),
    summary: text("summary"),
    /** JSON array of facts (each with its verbatim quote); null: no card yet. */
    facts: text("facts"),
    /** JSON array of the card's search words (what the document is called and synonyms, in the
     *  family's and the document's language); null: no card yet, or one made before them. */
    keywords: text("keywords"),
    docDate: text("doc_date"), // YYYY-MM-DD
    personUserId: text("person_user_id").references(() => users.id, { onDelete: "set null" }),
    personPersonId: text("person_person_id").references(() => familyPeople.id, { onDelete: "set null" }),
    /** When the current text was chunked; null while it waits (or failed). */
    indexedAt: integer("indexed_at", { mode: "timestamp" }),
    missingSince: integer("missing_since", { mode: "timestamp" }),
    runToken: text("run_token"),
    runUntil: integer("run_until", { mode: "timestamp" }),
    /** The worker's claims of the current text (a lost lease is run again once, then failed);
     *  back to 0 with new text, a reindex or letting it back in. */
    attempts: integer("attempts").notNull().default(0),
    /** The card (lib/knowledge/card.ts): pending (waiting for the worker, or for the family's AI) |
     *  ready | failed (`cardError`) | none (no text to make one of). Back to pending, without
     *  summary, facts, date and person, whenever the chunks change. */
    cardStatus: text("card_status").notNull().default("pending"),
    /** The card runner's lease (lib/knowledge/card-runner.ts), cleared like `runToken`; without
     *  a token `cardRunUntil` is when a card that failed for the time being is tried again. */
    cardRunToken: text("card_run_token"),
    cardRunUntil: integer("card_run_until", { mode: "timestamp" }),
    /** Claims of the current card (a lost lease runs once more, then the card failed). */
    cardAttempts: integer("card_attempts").notNull().default(0),
    /** Temporary failures of the current card (the AI busy or unreachable): each waits longer
     *  (`cardRunUntil` without a token is "not before"), the fifth fails the card. */
    cardRetries: integer("card_retries").notNull().default(0),
    cardError: text("card_error"),
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
    updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({
    kbDocumentsPathUniq: uniqueIndex("kb_documents_path_uniq").on(t.folderId, t.path),
    kbDocumentsStatusIdx: index("kb_documents_status_idx").on(t.familyId, t.status),
    /** The worker's queue: pending documents whose lease is free or ran out. */
    kbDocumentsQueueIdx: index("kb_documents_queue_idx").on(t.status, t.runUntil),
    /** The card runner's queue: ready documents waiting for a card. */
    kbDocumentsCardQueueIdx: index("kb_documents_card_queue_idx").on(t.cardStatus, t.status, t.cardRunUntil),
  }),
);

/** A piece of a document's text (about 1 000 characters, never across pages), in order (`seq`).
 *  The integer id is the FTS5 rowid and the assistant's source ref (`k:<id>`). */
export const kbChunks = sqliteTable(
  "kb_chunks",
  {
    id: integer("id").primaryKey({ autoIncrement: true }),
    documentId: text("document_id")
      .notNull()
      .references(() => kbDocuments.id, { onDelete: "cascade" }),
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    seq: integer("seq").notNull(),
    /** 1-based page of the document. */
    page: integer("page").notNull(),
    text: text("text").notNull(),
  },
  (t) => ({ kbChunksDocumentIdx: index("kb_chunks_document_idx").on(t.documentId, t.seq) }),
);

/** A page of a document the app sent as a picture (a JPEG under MEDIA_ROOT, `path`) for the
 *  family's AI to transcribe (lib/knowledge/scans.ts, scan-runner.ts): waiting | running | done |
 *  failed (`error`). `forced`: an editor asked for it (sent whatever the family's setting says).
 *  `hash`: the document's hash the scan was made for. The file is deleted once the scan is done or
 *  failed; the row goes with the document's text (replaced) and after 7 days. `runToken` /
 *  `runUntil` are the worker's lease (without a token `runUntil` is "not before": a scan that
 *  failed for the time being); `attempts` its claims, `retries` its temporary failures. */
export const kbPageScans = sqliteTable(
  "kb_page_scans",
  {
    documentId: text("document_id")
      .notNull()
      .references(() => kbDocuments.id, { onDelete: "cascade" }),
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    /** 1-based page of the document. */
    page: integer("page").notNull(),
    hash: text("hash").notNull(),
    path: text("path").notNull(),
    forced: integer("forced", { mode: "boolean" }).notNull().default(false),
    status: text("status").notNull().default("waiting"),
    error: text("error"),
    runToken: text("run_token"),
    runUntil: integer("run_until", { mode: "timestamp" }),
    attempts: integer("attempts").notNull().default(0),
    retries: integer("retries").notNull().default(0),
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
    updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({
    pk: primaryKey({ columns: [t.documentId, t.page] }),
    /** The scan runner's queue. */
    kbPageScansQueueIdx: index("kb_page_scans_queue_idx").on(t.status, t.runUntil),
    kbPageScansFamilyIdx: index("kb_page_scans_family_idx").on(t.familyId, t.status),
  }),
);
