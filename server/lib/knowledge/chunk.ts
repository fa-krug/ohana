// A document's text cut into chunks for the search (pure): about CHUNK_TARGET characters each,
// never more than CHUNK_MAX, never across pages. A page is cut where it reads best: between
// paragraphs (blank lines), else between lines, else after a sentence, else between words, and
// only a run without any of them (a giant word, CJK text without punctuation) at a fixed length.
// Small paragraphs are put together up to the target. Nothing is lost but whitespace: the
// whitespace a cut falls on, the lines' trailing spaces, runs of 3+ newlines (made 2) and the
// chunks' ends (trimmed). Empty pages give no chunks; pages keep their numbers.

/** The length a chunk aims for (UTF-16 code units, as JavaScript counts). */
export const CHUNK_TARGET = 1000;
/** The longest a chunk gets: a paragraph up to this length stays whole. */
export const CHUNK_MAX = 1500;
/** A chunk shorter than this takes the next piece as long as both fit in CHUNK_MAX. */
export const CHUNK_MIN = 500;

export interface TextChunk {
  /** Position in the document, from 0. */
  seq: number;
  /** The page it is on, from 1. */
  page: number;
  text: string;
}

/** A piece of a page and the whitespace that followed it there ("" at the end, or where the cut
 *  needs none). */
interface Piece {
  text: string;
  sep: string;
}

/** Where a page may be cut, best first: paragraphs, lines, sentence ends, whitespace. A
 *  sentence ends at . ! ? … (and the CJK 。！？), perhaps followed by closing quotes (English,
 *  German, French) or brackets; after a CJK one the cut needs no whitespace. */
const BREAKS: RegExp[] = [
  /\n{2,}/g,
  /\n/g,
  /(?<=[.!?…。！？]["'“”‘’»«›‹)\]」』]*)\s+|(?<=[。！？]["'“”‘’»«›‹)\]」』]*)(?=\S)/gu,
  /\s+/g,
];

/** The page as it is stored in chunks: line ends unified, trailing whitespace of each line
 *  gone, at most one blank line in a row, trimmed. */
export function normalizePage(text: string): string {
  return text
    .replace(/\r\n?/g, "\n")
    .replace(/[^\S\n]+$/gm, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** `text` cut at every match of `re` (non-empty pieces only; a leading or trailing separator is
 *  whitespace that goes). */
function cutAt(text: string, re: RegExp): Piece[] {
  const out: Piece[] = [];
  let from = 0;
  for (const m of text.matchAll(re)) {
    const at = m.index;
    if (at > from) out.push({ text: text.slice(from, at), sep: m[0] });
    else if (out.length) out[out.length - 1].sep += m[0];
    from = at + m[0].length;
  }
  if (from < text.length) out.push({ text: text.slice(from), sep: "" });
  return out;
}

/** Fixed lengths of CHUNK_TARGET, never between the two halves of a surrogate pair. */
function hardCut(text: string): Piece[] {
  const out: Piece[] = [];
  let from = 0;
  while (from < text.length) {
    let to = Math.min(from + CHUNK_TARGET, text.length);
    const code = text.charCodeAt(to - 1);
    if (to < text.length && code >= 0xd800 && code <= 0xdbff) to -= 1;
    out.push({ text: text.slice(from, to), sep: "" });
    from = to;
  }
  return out;
}

/** `text` in pieces of at most CHUNK_MAX: cut at the best kind of break it has (from `level`
 *  on), pieces still too long cut further at the next kinds. A page that fits in CHUNK_MAX
 *  stays one chunk (packing its paragraphs would only give a small last one back to merge). */
function pieces(text: string, level = 0): Piece[] {
  if (text.length <= CHUNK_MAX) return [{ text, sep: "" }];
  if (level >= BREAKS.length) return hardCut(text);
  const parts = cutAt(text, BREAKS[level]);
  if (parts.length <= 1) return pieces(parts[0]?.text ?? text, level + 1);
  const out: Piece[] = [];
  for (const part of parts) {
    const sub = pieces(part.text, level + 1);
    sub[sub.length - 1].sep = part.sep;
    out.push(...sub);
  }
  return out;
}

/** The pieces put together in order: a piece joins the chunk while that stays within the
 *  target, or within the maximum while the chunk is still small; a small last chunk joins the
 *  one before if they fit. */
function pack(list: Piece[]): string[] {
  const chunks: Piece[] = [];
  let cur: Piece | null = null;
  for (const p of list) {
    if (cur) {
      const joined = cur.text.length + cur.sep.length + p.text.length;
      if (joined <= CHUNK_TARGET || (cur.text.length < CHUNK_MIN && joined <= CHUNK_MAX)) {
        cur = { text: cur.text + cur.sep + p.text, sep: p.sep };
        continue;
      }
      chunks.push(cur);
    }
    cur = { ...p };
  }
  if (cur) {
    const last = chunks[chunks.length - 1];
    if (last && cur.text.length < CHUNK_MIN && last.text.length + last.sep.length + cur.text.length <= CHUNK_MAX) {
      chunks[chunks.length - 1] = { text: last.text + last.sep + cur.text, sep: cur.sep };
    } else {
      chunks.push(cur);
    }
  }
  return chunks.map((c) => c.text.trim()).filter((t) => t.length > 0);
}

/** The chunks of one page's text. */
export function chunkPage(text: string): string[] {
  const page = normalizePage(text);
  return page ? pack(pieces(page)) : [];
}

/** A document's pages (the uploaded text, in order) as chunks, numbered through the document. */
export function chunkPages(pages: readonly string[]): TextChunk[] {
  const out: TextChunk[] = [];
  pages.forEach((text, i) => {
    for (const chunk of chunkPage(text)) out.push({ seq: out.length, page: i + 1, text: chunk });
  });
  return out;
}

/** The pages of a document's stored `text` column (a JSON array of strings). Empty or null text
 *  has no pages (the document becomes ready without chunks: the app shows it has no text);
 *  anything else that isn't a list of strings throws. */
export function storedPages(raw: string | null | undefined): string[] {
  if (raw == null || raw.trim() === "") return [];
  const v: unknown = JSON.parse(raw);
  if (v === null) return [];
  if (!Array.isArray(v) || v.some((p) => typeof p !== "string")) throw new Error("The stored text isn't a list of pages");
  return v as string[];
}
