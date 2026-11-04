// Full-text search over the knowledge base's chunks (SQLite FTS5, `kb_chunks_fts`: case and
// diacritics ignored, so "kundigung" finds "Kündigung"). Free text becomes a safe FTS query: each
// word quoted as a prefix ("künd"*), all of them first, any of them when that finds nothing.
// Only the family's ready and pending documents count (a pending one has chunks only while a
// reindex waits: new text deletes them at once); the best (bm25) come first.

import { and, eq, inArray, sql, type SQL } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { kbChunks, kbDocuments } from "@/lib/db/schema";
import { hasTag, inFolder } from "./documents";

export const SEARCH_DEFAULT_LIMIT = 10;
export const SEARCH_MAX_LIMIT = 50;
/** Words of a query that count (a pasted paragraph mustn't make a huge query). */
const MAX_WORDS = 16;

export interface KnowledgeHit {
  chunkId: number;
  documentId: string;
  name: string;
  path: string;
  page: number;
  text: string;
  /** The chunk's best part, the matched words in **…**. */
  snippet: string;
}

export interface SearchOptions {
  limit?: number;
  /** Documents carrying all of them. */
  tags?: string[];
  /** A subfolder of the folder ("Versicherungen/Auto"). */
  folder?: string | null;
}

/** The words of free text as FTS5 prefix terms ("word"*); none for text without letters or digits. */
export function ftsTerms(query: string): string[] {
  const words = query.normalize("NFC").match(/[\p{L}\p{N}\p{M}]+/gu) ?? [];
  return [...new Set(words)].slice(0, MAX_WORDS).map((w) => `"${w}"*`);
}

/** The family's chunks matching `query` (all words, else any), best first. */
export function searchKnowledge(db: Db, familyId: string, query: string, opts: SearchOptions = {}): KnowledgeHit[] {
  const terms = ftsTerms(query);
  if (terms.length === 0) return [];
  const limit = Math.min(Math.max(opts.limit ?? SEARCH_DEFAULT_LIMIT, 1), SEARCH_MAX_LIMIT);
  const filters: SQL[] = [eq(kbChunks.familyId, familyId), inArray(kbDocuments.status, ["ready", "pending"])];
  for (const tag of opts.tags ?? []) filters.push(hasTag(tag.normalize("NFC")));
  if (opts.folder) filters.push(inFolder(opts.folder));
  const run = (match: string) =>
    db.all<KnowledgeHit>(sql`
      select ${kbChunks.id} as chunkId, ${kbChunks.documentId} as documentId, ${kbDocuments.name} as name,
             ${kbDocuments.path} as path, ${kbChunks.page} as page, ${kbChunks.text} as text,
             snippet(kb_chunks_fts, 0, '**', '**', '…', 24) as snippet
      from kb_chunks_fts
      join ${kbChunks} on ${kbChunks.id} = kb_chunks_fts.rowid
      join ${kbDocuments} on ${kbDocuments.id} = ${kbChunks.documentId}
      where kb_chunks_fts match ${match} and ${and(...filters)}
      order by bm25(kb_chunks_fts), ${kbChunks.id}
      limit ${limit}`);
  const all = run(terms.join(" "));
  return all.length > 0 || terms.length === 1 ? all : run(terms.join(" OR "));
}
