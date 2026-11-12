// Search over the knowledge base. A document is found by the text of its chunks (SQLite FTS5,
// `kb_chunks_fts`: case and diacritics ignored, so "kundigung" finds "Kündigung") and by what
// describes it: its path (name and folders), tags and card summary. A scanned timetable whose
// text is only its table is still found as "Stundenplan" by its file name. Free text becomes
// words, each matching a word's beginning ("künd" finds "Kündigung"); passages covering every
// word (in their text or their document's description) come first, else those covering most.
// Among them, documents whose path or tags hold more of the words come first, of those the newest
// (the card's date, else the file's), so a new version of a document beats the old one; then the
// best (bm25) passages. Only the family's ready and pending documents count (a pending one has
// chunks only while a reindex waits: new text deletes them at once).

import { and, eq, inArray, sql, type SQL } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { kbChunks, kbDocuments } from "@/lib/db/schema";
import { normalizeForSearch } from "@/lib/meals/domain/recipes/search";
import { hasTag, inFolder, parseJsonArray } from "./documents";

export const SEARCH_DEFAULT_LIMIT = 10;
export const SEARCH_MAX_LIMIT = 50;
/** Words of a query that count (a pasted paragraph mustn't make a huge query). */
const MAX_WORDS = 16;
/** Documents found by their description whose passages are looked up, the best first. */
const MAX_DESCRIBED = 200;
/** Words of a passage's plain snippet (one that doesn't hold the words). */
const PLAIN_SNIPPET_WORDS = 24;

export interface KnowledgeHit {
  chunkId: number;
  documentId: string;
  name: string;
  path: string;
  page: number;
  text: string;
  /** The chunk's best part, the matched words in **…**. */
  snippet: string;
  /** "YYYY-MM-DD": the document's date (its card's), else the file's last change; null unknown. */
  date: string | null;
  /** The document's card summary (2–4 sentences by the assistant); null before its card. */
  summary: string | null;
}

export interface SearchOptions {
  limit?: number;
  /** Documents carrying all of them. */
  tags?: string[];
  /** A subfolder of the folder ("Versicherungen/Auto"). */
  folder?: string | null;
}

const WORD = /[\p{L}\p{N}\p{M}]+/gu;

/** The words of free text, each once, at most MAX_WORDS. */
function queryWords(query: string): string[] {
  return [...new Set(query.normalize("NFC").match(WORD) ?? [])].slice(0, MAX_WORDS);
}

/** The words of free text as FTS5 prefix terms ("word"*); none for text without letters or digits. */
export function ftsTerms(query: string): string[] {
  return queryWords(query).map((w) => `"${w}"*`);
}

/** Text's words folded as the index folds them (case, accents). */
function foldedWords(text: string): string[] {
  return normalizeForSearch(text.normalize("NFC")).match(WORD) ?? [];
}

/** Which of the folded query words begin one of `words`. */
function covered(query: string[], words: string[]): boolean[] {
  return query.map((q) => words.some((w) => w.startsWith(q)));
}

const count = (flags: boolean[]) => flags.filter(Boolean).length;

/** What describes a document: which query words its path or tags hold (`title`), and which its
 *  path, tags or summary (`described`). */
interface Described {
  title: boolean[];
  described: boolean[];
  date: string | null;
  summary: string | null;
}

/** The family's chunks matching `query`, best first (see the top of the file). */
export function searchKnowledge(db: Db, familyId: string, query: string, opts: SearchOptions = {}): KnowledgeHit[] {
  const words = queryWords(query);
  if (words.length === 0) return [];
  const folded = words.map((w) => normalizeForSearch(w));
  const term = (w: string) => `"${w}"*`;
  const all = words.map(term).join(" OR ");
  const limit = Math.min(Math.max(opts.limit ?? SEARCH_DEFAULT_LIMIT, 1), SEARCH_MAX_LIMIT);

  const docFilters: SQL[] = [eq(kbDocuments.familyId, familyId), inArray(kbDocuments.status, ["ready", "pending"])];
  for (const tag of opts.tags ?? []) docFilters.push(hasTag(tag.normalize("NFC")));
  if (opts.folder) docFilters.push(inFolder(opts.folder));

  // The documents that may be found, and what of the query describes each.
  const docs = new Map<string, Described>();
  for (const d of db
    .select({ id: kbDocuments.id, path: kbDocuments.path, tags: kbDocuments.tags, summary: kbDocuments.summary, docDate: kbDocuments.docDate, mtime: kbDocuments.mtime })
    .from(kbDocuments)
    .where(and(...docFilters))
    .all()) {
    const title = covered(folded, foldedWords([d.path, ...(parseJsonArray<string>(d.tags) ?? [])].join(" ")));
    const inSummary = d.summary ? covered(folded, foldedWords(d.summary)) : folded.map(() => false);
    docs.set(d.id, {
      title,
      described: title.map((t, i) => t || inSummary[i]),
      date: d.docDate ?? (d.mtime > 0 ? new Date(d.mtime).toISOString().slice(0, 10) : null),
      summary: d.summary,
    });
  }
  if (docs.size === 0) return [];

  /** Chunk ids of the documents' chunks matching `match`, best first. */
  const matching = (match: string, where: SQL[], max?: number) =>
    db.all<{ chunkId: number; documentId: string }>(sql`
      select ${kbChunks.id} as chunkId, ${kbChunks.documentId} as documentId
      from kb_chunks_fts
      join ${kbChunks} on ${kbChunks.id} = kb_chunks_fts.rowid
      join ${kbDocuments} on ${kbDocuments.id} = ${kbChunks.documentId}
      where kb_chunks_fts match ${match} and ${and(...docFilters, ...where)}
      order by bm25(kb_chunks_fts), ${kbChunks.id}
      ${max === undefined ? sql`` : sql`limit ${max}`}`);

  // Candidate passages, in the index's order: those with every word, those with any…
  const found = new Map<number, { documentId: string; every: boolean }>();
  const add = (rows: { chunkId: number; documentId: string }[], every = false) => {
    for (const r of rows) if (!found.has(r.chunkId)) found.set(r.chunkId, { documentId: r.documentId, every });
  };
  add(matching(words.map(term).join(" "), [], limit), true);
  if (words.length > 1) add(matching(all, [], limit * 3));

  // …and the best passage of each document its description finds: one with the words its
  // description lacks, else one with any word, else its first.
  const described = [...docs]
    .filter(([, d]) => d.described.some(Boolean))
    .sort(([, a], [, b]) => count(b.described) - count(a.described) || count(b.title) - count(a.title) || newer(a.date, b.date))
    .slice(0, MAX_DESCRIBED);
  const best = new Map<string, number>();
  const firstPer = (rows: { chunkId: number; documentId: string }[]) => {
    for (const r of rows) if (!best.has(r.documentId)) best.set(r.documentId, r.chunkId);
  };
  const lacking = new Map<string, string[]>();
  for (const [id, d] of described) {
    const missing = words.filter((_, i) => !d.described[i]);
    if (missing.length === 0) continue;
    const key = missing.join(" ");
    lacking.set(key, [...(lacking.get(key) ?? []), id]);
  }
  for (const [key, ids] of lacking) firstPer(matching(key.split(" ").map(term).join(" "), [inArray(kbChunks.documentId, ids)]));
  const rest = () => described.map(([id]) => id).filter((id) => !best.has(id));
  if (rest().length) firstPer(matching(all, [inArray(kbChunks.documentId, rest())]));
  if (rest().length) {
    firstPer(
      db
        .select({ chunkId: kbChunks.id, documentId: kbChunks.documentId })
        .from(kbChunks)
        .where(inArray(kbChunks.documentId, rest()))
        .orderBy(kbChunks.documentId, kbChunks.seq)
        .all(),
    );
  }
  add(described.flatMap(([id]) => (best.has(id) ? [{ chunkId: best.get(id)!, documentId: id }] : [])));
  if (found.size === 0) return [];

  const rows = new Map(
    db
      .select({ chunkId: kbChunks.id, documentId: kbChunks.documentId, name: kbDocuments.name, path: kbDocuments.path, page: kbChunks.page, text: kbChunks.text })
      .from(kbChunks)
      .innerJoin(kbDocuments, eq(kbDocuments.id, kbChunks.documentId))
      .where(inArray(kbChunks.id, [...found.keys()]))
      .all()
      .map((r) => [r.chunkId, r]),
  );

  // How many words each passage covers, with its document's description.
  const ranked = [...found]
    .flatMap(([chunkId, f], order) => {
      const row = rows.get(chunkId);
      const doc = docs.get(f.documentId);
      if (!row || !doc) return [];
      const inText = f.every ? folded.map(() => true) : covered(folded, foldedWords(row.text));
      return [{ row, doc, order, words: count(inText.map((t, i) => t || doc.described[i])) }];
    });
  const most = Math.max(...ranked.map((r) => r.words));
  const chosen = ranked
    .filter((r) => r.words === most)
    .sort((a, b) => {
      const titles = count(b.doc.title) - count(a.doc.title);
      if (titles) return titles;
      if (count(a.doc.title) > 0) return newer(a.doc.date, b.doc.date) || a.order - b.order;
      return a.order - b.order;
    })
    .slice(0, limit);

  const snippets = new Map(
    db
      .all<{ chunkId: number; snippet: string }>(sql`
        select rowid as chunkId, snippet(kb_chunks_fts, 0, '**', '**', '…', 24) as snippet
        from kb_chunks_fts
        where kb_chunks_fts match ${all} and rowid in (${sql.join(chosen.map((c) => sql`${c.row.chunkId}`), sql`, `)})`)
      .map((s) => [s.chunkId, s.snippet]),
  );
  return chosen.map(({ row, doc }) => ({
    ...row,
    snippet: snippets.get(row.chunkId) ?? plainSnippet(row.text),
    date: doc.date,
    summary: doc.summary,
  }));
}

/** Newest first; unknown dates last. */
function newer(a: string | null, b: string | null): number {
  if (a === b) return 0;
  if (a === null) return 1;
  if (b === null) return -1;
  return a < b ? 1 : -1;
}

/** The start of a passage that doesn't hold the words. */
function plainSnippet(text: string): string {
  const words = text.split(/\s+/).filter(Boolean);
  return words.slice(0, PLAIN_SNIPPET_WORDS).join(" ") + (words.length > PLAIN_SNIPPET_WORDS ? "…" : "");
}
