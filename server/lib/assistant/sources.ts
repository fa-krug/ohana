// The source check of the assistant's answers: a statement taken from the knowledge base ends
// with a marker `[[k:<chunkId>]]` (the `ref` a knowledge tool gave; spaces inside are allowed).
// When an answer is saved as a chat item, a marker stays (written `[[k:<id>]]`) only if a
// knowledge tool of this server returned that ref in the same chat (recorded as the tools run:
// `chats.knowledge_refs`, never from an imported history) and the chunk is still the family's;
// the others are taken out of the text. The item gets `sources`, one per ref in order of first
// appearance, for the app's chips. Only the saved copy is checked: the text a turn is still
// writing keeps its half-written markers until they are whole.

import { type CitedChunk, excerptOf } from "@/lib/knowledge/sources";

/** A source marker in an answer, with the spaces before it (removed with an invalid one). */
const MARKER = /([ \t]*)\[\[[ \t]*k[ \t]*:[ \t]*(\d{1,15})[ \t]*\]\]/g;
/** Private-use characters the app uses as placeholders while it renders an answer. */
const PLACEHOLDERS = /[]/g;

export interface Source {
  ref: string;
  chunkId: number;
  documentId: string;
  name: string;
  path: string;
  page: number;
  /** The chunk's whole text. */
  quote: string;
  /** The part of `quote` that backs the statement (≤ 300 characters). */
  excerpt: string;
}

/** The chunk ids `text` cites (once each, in order). */
export function citedIds(text: string): number[] {
  return [...new Set([...text.matchAll(MARKER)].map((m) => Number(m[2])))];
}

/** The statement right before position `at` of an answer: its last sentence (or line) there,
 *  without markers. */
export function statementBefore(text: string, at: number): string {
  const before = text
    .slice(Math.max(0, at - 800), at)
    .replace(MARKER, " ")
    .replace(/[\s.!?;:,]+$/u, "");
  const parts = before.split(/(?<=[.!?…])\s+|\n+/);
  return parts.at(-1) ?? "";
}

/** The answer as it is saved: without the app's placeholder characters, with only the markers
 *  of `allowed` refs whose chunk `known` has (written the one way), and its sources. */
export function checkSources(
  raw: string,
  allowed: ReadonlySet<number>,
  known: ReadonlyMap<number, CitedChunk>,
): { text: string; sources: Source[] } {
  const text = raw.replace(PLACEHOLDERS, "");
  const sources = new Map<number, Source>();
  const out = text.replace(MARKER, (_marker, lead: string, digits: string, offset: number) => {
    const id = Number(digits);
    const chunk = allowed.has(id) ? known.get(id) : undefined;
    if (!chunk) return "";
    if (!sources.has(id)) {
      const { facts, text: quote, ...rest } = chunk;
      sources.set(id, { ref: `k:${id}`, ...rest, quote, excerpt: excerptOf({ text: quote, facts }, statementBefore(text, offset)) });
    }
    return `${lead}[[k:${id}]]`;
  });
  return { text: out, sources: [...sources.values()] };
}

/** Takes every marker out (imported chats, which no tool of this server answered). */
export const withoutMarkers = (text: string) => text.replace(MARKER, "");
