// The knowledge base's chunks (lib/knowledge/chunk.ts): about 1 000 characters, cut between
// paragraphs, else lines, else sentences, else words, else at a fixed length; never across pages,
// page numbers kept, empty pages skipped, and nothing lost but whitespace.

import { describe, expect, it } from "vitest";
import { CHUNK_MAX, CHUNK_MIN, CHUNK_TARGET, chunkPage, chunkPages, normalizePage, storedPages } from "@/lib/knowledge/chunk";

const squeeze = (s: string) => s.replace(/\s+/g, "");

/** Every chunk within the maximum, trimmed and not empty; together they hold the page's text. */
function expectCovers(pages: string[]) {
  const chunks = chunkPages(pages);
  for (const c of chunks) {
    expect(c.text.length, JSON.stringify(c.text.slice(0, 40))).toBeLessThanOrEqual(CHUNK_MAX);
    expect(c.text).toBe(c.text.trim());
    expect(c.text).not.toBe("");
  }
  expect(chunks.map((c) => c.seq)).toEqual(chunks.map((_, i) => i));
  pages.forEach((page, i) => {
    const own = chunks.filter((c) => c.page === i + 1).map((c) => c.text);
    expect(squeeze(own.join(""))).toBe(squeeze(page));
  });
  return chunks;
}

/** A sentence of `n` words (about 7n characters) ending with a full stop. */
const sentence = (n: number, word = "word") => `${Array.from({ length: n }, (_, i) => `${word}${i}`).join(" ")}.`;

describe("knowledge: chunks", () => {
  it("keeps a short page as one chunk, trimmed", () => {
    expect(chunkPages(["  Hello world.\n\n  "])).toEqual([{ seq: 0, page: 1, text: "Hello world." }]);
    // Up to the maximum, paragraphs and all.
    const page = Array.from({ length: 13 }, (_, i) => sentence(15, `p${i}w`)).join("\n\n");
    expect(page.length).toBeGreaterThan(CHUNK_TARGET);
    expect(page.length).toBeLessThanOrEqual(CHUNK_MAX);
    expect(chunkPage(page)).toEqual([page]);
  });

  it("skips empty pages but keeps the pages' numbers", () => {
    const chunks = expectCovers(["", "First page.", "  \n\t\n ", "\n\n\n", "Fifth page."]);
    expect(chunks).toEqual([
      { seq: 0, page: 2, text: "First page." },
      { seq: 1, page: 5, text: "Fifth page." },
    ]);
    expect(chunkPages([])).toEqual([]);
    expect(chunkPages(["", " "])).toEqual([]);
  });

  it("never puts two pages in one chunk", () => {
    const chunks = expectCovers(["One.", "Two.", "Three."]);
    expect(chunks.map((c) => [c.page, c.text])).toEqual([
      [1, "One."],
      [2, "Two."],
      [3, "Three."],
    ]);
  });

  it("normalizes whitespace: line ends, trailing spaces, blank lines", () => {
    expect(normalizePage("a  \r\nb\t\rc\n\n\n\n\nd  \n \n")).toBe("a\nb\nc\n\nd");
    expect(chunkPage("Title   \n\n\n\n\nBody text  \nmore")).toEqual(["Title\n\nBody text\nmore"]);
  });

  it("puts small paragraphs together up to the target, cutting between paragraphs", () => {
    const paragraphs = Array.from({ length: 30 }, (_, i) => sentence(20, `p${i}w`)); // ~ 100 each
    const page = paragraphs.join("\n\n");
    const chunks = expectCovers([page]);
    expect(chunks.length).toBeGreaterThan(1);
    for (const c of chunks) {
      // The target, but the last: a small remainder joined it.
      if (c !== chunks[chunks.length - 1]) expect(c.text.length).toBeLessThanOrEqual(CHUNK_TARGET);
      // Whole paragraphs only.
      for (const part of c.text.split("\n\n")) expect(paragraphs).toContain(part);
    }
    // Every chunk but the last is full: the next paragraph didn't fit any more.
    for (const c of chunks.slice(0, -1)) expect(c.text.length).toBeGreaterThan(CHUNK_TARGET - 120);
  });

  it("keeps a paragraph up to the maximum whole", () => {
    const long = sentence(170); // ~ 1 200
    expect(long.length).toBeGreaterThan(CHUNK_TARGET);
    expect(long.length).toBeLessThanOrEqual(CHUNK_MAX);
    const chunks = expectCovers([`${sentence(80)}\n\n${long}\n\n${sentence(80)}`]);
    expect(chunks.map((c) => c.text)).toContain(long);
  });

  it("cuts a long paragraph at its line breaks", () => {
    const lines = Array.from({ length: 40 }, (_, i) => `Line ${i}: ${"abc ".repeat(12).trim()}`); // ~ 57 each
    const chunks = expectCovers([lines.join("\n")]);
    expect(chunks.length).toBeGreaterThan(1);
    for (const c of chunks) for (const line of c.text.split("\n")) expect(lines).toContain(line);
  });

  it("cuts a long line at sentence ends", () => {
    const sentences = Array.from({ length: 30 }, (_, i) => `Sentence ${i} says ${"blah ".repeat(10).trim()}!`);
    const chunks = expectCovers([sentences.join(" ")]);
    expect(chunks.length).toBeGreaterThan(1);
    for (const c of chunks) {
      expect(c.text).toMatch(/^Sentence \d+ /);
      expect(c.text).toMatch(/!$/);
    }
  });

  it("knows sentences ending in quotes and brackets", () => {
    const sentences = Array.from({ length: 30 }, (_, i) => `„Satz ${i} ist ${"lang ".repeat(10).trim()}.“`);
    const chunks = expectCovers([sentences.join(" ")]);
    for (const c of chunks) expect(c.text).toMatch(/\.“$/);
  });

  it("cuts a sentence that is too long between words", () => {
    const words = sentence(600); // one sentence, ~ 4 000 characters
    const chunks = expectCovers([words]);
    expect(chunks.length).toBeGreaterThanOrEqual(3);
    for (const c of chunks) expect(c.text).toMatch(/^word\d+ .* word\d+\.?$/);
  });

  it("cuts a single giant word at a fixed length", () => {
    const word = "x".repeat(3400);
    const chunks = expectCovers([word]);
    expect(chunks.map((c) => c.text.length)).toEqual([1000, 1000, 1400]);
    expect(chunks.map((c) => c.text).join("")).toBe(word);
  });

  it("leaves a big enough remainder of a giant word on its own", () => {
    const chunks = expectCovers(["y".repeat(2700)]);
    expect(chunks.map((c) => c.text.length)).toEqual([1000, 1000, 700]);
  });

  it("cuts CJK text at its sentence ends without needing spaces", () => {
    const s = "これは日本語の文章です。"; // 12 characters
    const page = s.repeat(250); // 3 000, no whitespace at all
    const chunks = expectCovers([page]);
    expect(chunks.length).toBeGreaterThan(2);
    for (const c of chunks) {
      expect(c.text.endsWith("。")).toBe(true);
      expect(c.text.length % s.length).toBe(0);
    }
    expect(chunks.map((c) => c.text).join("")).toBe(page);
  });

  it("cuts CJK text without punctuation at a fixed length", () => {
    const page = "中文".repeat(1600);
    const chunks = expectCovers([page]);
    expect(chunks.map((c) => c.text).join("")).toBe(page);
  });

  it("never cuts a surrogate pair in half", () => {
    const page = `a${"😀".repeat(1500)}`; // 3 001 UTF-16 units, the pairs at odd offsets
    const chunks = expectCovers([page]);
    expect(chunks.map((c) => c.text).join("")).toBe(page);
    for (const c of chunks) {
      expect(c.text.codePointAt(0)).not.toBe(0xde00);
      expect(c.text.isWellFormed()).toBe(true);
    }
  });

  it("puts a small remainder with the chunk before", () => {
    const page = `${sentence(130)}\n\n${sentence(10)}`; // ~ 900 + ~ 70
    const chunks = expectCovers([page, `${sentence(140)}\n\n${sentence(140)}\n\nEnd.`]);
    expect(chunks.filter((c) => c.page === 1)).toHaveLength(1);
    const second = chunks.filter((c) => c.page === 2).map((c) => c.text);
    expect(second).toHaveLength(2);
    expect(second[1].endsWith("\n\nEnd.")).toBe(true);
  });

  it("covers a long mixed document", () => {
    const pages = [
      [sentence(30), sentence(400), "z".repeat(2300), "日本語の文章です。".repeat(300), "中".repeat(2500), "Tail."].join("\n\n"),
      Array.from({ length: 200 }, (_, i) => `Zeile ${i} mit Text`).join("\n"),
      "",
      `${sentence(50)}   \n\n\n\n   ${sentence(50)}`,
    ];
    const chunks = expectCovers(pages);
    expect(new Set(chunks.map((c) => c.page))).toEqual(new Set([1, 2, 4]));
    // About the target: none tiny but a page's last.
    const byPage = Map.groupBy(chunks, (c) => c.page);
    for (const list of byPage.values()) {
      for (const c of list.slice(0, -1)) expect(c.text.length).toBeGreaterThanOrEqual(CHUNK_MIN);
    }
  });
});

describe("knowledge: stored pages", () => {
  it("reads the stored JSON, empty or null text as no pages", () => {
    expect(storedPages('["a","b"]')).toEqual(["a", "b"]);
    expect(storedPages("[]")).toEqual([]);
    expect(storedPages("")).toEqual([]);
    expect(storedPages(null)).toEqual([]);
    expect(storedPages("null")).toEqual([]);
  });

  it("throws for anything else", () => {
    expect(() => storedPages("{nope")).toThrow();
    expect(() => storedPages('{"a":1}')).toThrow("list of pages");
    expect(() => storedPages('["a",2]')).toThrow("list of pages");
  });
});
