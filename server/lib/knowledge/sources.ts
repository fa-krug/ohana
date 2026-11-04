// The knowledge base as the assistant's source: who may use it in a chat, the chunks its answers
// cite (`[[k:<chunkId>]]`, checked in lib/assistant/sources.ts) with what the app shows of them,
// and the excerpt of a cited chunk: the sentences that back the statement.

import { and, eq, inArray } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { kbChunks, kbDocuments } from "@/lib/db/schema";
import { getRole } from "@/lib/families/roles";
import { moduleEnabled } from "@/lib/server-info";
import { type KnowledgeFact, parseJsonArray } from "./documents";
import { getFolder } from "./folders";

/** Characters of a source's excerpt at most. */
export const EXCERPT_MAX = 300;
/** Consecutive sentences an excerpt takes at most. */
const EXCERPT_SENTENCES = 3;

/** A cited chunk: its document, its whole text and the facts of the card that quote it. */
export interface CitedChunk {
  chunkId: number;
  documentId: string;
  name: string;
  path: string;
  page: number;
  text: string;
  facts: { text: string; quote: string }[];
}

/** Whether `userId`'s assistant may use the family's knowledge base: the module is on, they are
 *  an editor (viewers never see it), and the family has a knowledge folder. */
export function knowledgeForUser(db: Db, familyId: string, userId: string): boolean {
  return moduleEnabled("knowledge") && getRole(db, familyId, userId) === "editor" && !!getFolder(db, familyId);
}

/** The chunks among `ids` that exist in the family (excluded documents have none), by id. */
export function chunkSources(db: Db, familyId: string, ids: readonly number[]): Map<number, CitedChunk> {
  const out = new Map<number, CitedChunk>();
  if (!ids.length) return out;
  const rows = db
    .select({
      chunkId: kbChunks.id,
      documentId: kbChunks.documentId,
      name: kbDocuments.name,
      path: kbDocuments.path,
      page: kbChunks.page,
      text: kbChunks.text,
      facts: kbDocuments.facts,
    })
    .from(kbChunks)
    .innerJoin(kbDocuments, eq(kbDocuments.id, kbChunks.documentId))
    .where(and(eq(kbChunks.familyId, familyId), eq(kbDocuments.familyId, familyId), inArray(kbChunks.id, [...ids])))
    .all();
  for (const { facts, ...r } of rows) {
    const own = (parseJsonArray<KnowledgeFact>(facts) ?? [])
      .filter((f) => f && f.chunkId === r.chunkId && typeof f.quote === "string" && typeof f.text === "string")
      .map((f) => ({ text: f.text, quote: f.quote }));
    out.set(r.chunkId, { ...r, facts: own });
  }
  return out;
}

// ---- the excerpt ----

/** Words that say nothing about which sentence is meant. */
const STOP = new Set(
  ("the and for are was were has have had this that with from not but you your our their its " +
    "der die das und ist sind war ein eine einen einem einer des dem den mit von für auf aus bei " +
    "nicht auch wie als oder sie ihr ihre wir uns zum zur nach über unter")
    .split(" "),
);

/** The words of a text that count: case and accents folded, numbers and words of 3+ letters. */
export function wordsOf(text: string): string[] {
  const folded = text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
  return (folded.match(/[\p{L}\p{N}]+/gu) ?? []).filter((w) => (/\d/.test(w) || w.length >= 3) && !STOP.has(w));
}

/** How many of the statement's words the text has (a word of 5+ letters also by its first 5:
 *  "Kündigung" finds "Kündigungsfrist"). */
function overlap(statement: ReadonlySet<string>, text: string): number {
  const words = wordsOf(text);
  const exact = new Set(words);
  const stems = new Set(words.filter((w) => w.length >= 5).map((w) => w.slice(0, 5)));
  let n = 0;
  for (const w of statement) if (exact.has(w) || (w.length >= 5 && stems.has(w.slice(0, 5)))) n++;
  return n;
}

/** The sentences of a text as [start, end) spans, without the whitespace around them. */
function sentences(text: string): [number, number][] {
  const out: [number, number][] = [];
  const push = (start: number, end: number) => {
    while (start < end && /\s/.test(text[start])) start++;
    while (end > start && /\s/.test(text[end - 1])) end--;
    if (end > start) out.push([start, end]);
  };
  const re = /[.!?…]+(?=\s)|\n+/g;
  let start = 0;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    const end = m[0][0] === "\n" ? m.index : m.index + m[0].length;
    push(start, end);
    start = m.index + m[0].length;
  }
  push(start, text.length);
  return out;
}

/** A span cut to EXCERPT_MAX characters at a word (still a part of the text). */
function fit(text: string, [start, end]: [number, number]): string {
  const s = text.slice(start, end);
  if (s.length <= EXCERPT_MAX) return s;
  const cut = s.slice(0, EXCERPT_MAX);
  const space = cut.search(/\s\S*$/);
  return (space > EXCERPT_MAX / 2 ? cut.slice(0, space) : cut).trimEnd();
}

/** The part of the chunk that backs `statement`: the 1–3 consecutive sentences (at most
 *  EXCERPT_MAX characters) sharing the most words with it, or the quote of a card fact of the
 *  chunk that matches it at least as well; the first sentence when nothing matches. Always a part
 *  of `chunk.text`. */
export function excerptOf(chunk: Pick<CitedChunk, "text" | "facts">, statement: string): string {
  const text = chunk.text;
  const spans = sentences(text);
  if (!spans.length) return "";
  const words = new Set(wordsOf(statement));
  let best = { score: 0, excerpt: fit(text, spans[0]) };
  if (!words.size) return best.excerpt;
  for (let i = 0; i < spans.length; i++) {
    for (let k = 1; k <= EXCERPT_SENTENCES && i + k <= spans.length; k++) {
      const span: [number, number] = [spans[i][0], spans[i + k - 1][1]];
      if (k > 1 && span[1] - span[0] > EXCERPT_MAX) break;
      const excerpt = fit(text, span);
      const score = overlap(words, excerpt);
      if (score > best.score || (score === best.score && score > 0 && excerpt.length < best.excerpt.length)) {
        best = { score, excerpt };
      }
    }
  }
  for (const fact of chunk.facts) {
    if (fact.quote.length > EXCERPT_MAX || !text.includes(fact.quote)) continue;
    const score = overlap(words, `${fact.text} ${fact.quote}`);
    if (score > 0 && score >= best.score) best = { score, excerpt: fact.quote };
  }
  return best.excerpt;
}
