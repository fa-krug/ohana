// The assistant's tools for the family's knowledge base (lib/knowledge/): search the documents
// (their text, names, folders, tags and summaries), read a document (its card and its text, a
// page at a time when it is long), list the values the documents report (lab results, grades,
// readings …) across documents and over time. Read-only, and only for editors with the module on
// (ToolContext.knowledge): viewers never get them. Every piece of text comes with its `ref`
// ("k:<chunkId>"), which the answer cites as `[[k:<chunkId>]]`; the chat keeps only refs these tools returned (lib/assistant/sources.ts).

import { asc, eq } from "drizzle-orm";
import { HttpError } from "@/lib/api/http";
import { kbChunks } from "@/lib/db/schema";
import { isValidDate } from "@/lib/calendar/dates";
import { familyNames } from "@/lib/families/people";
import { matchPerson } from "@/lib/knowledge/card";
import { getDocumentRow, type KnowledgeFact, type KnowledgeValue, parseJsonArray } from "@/lib/knowledge/documents";
import { searchKnowledge } from "@/lib/knowledge/search";
import { knowledgeForUser } from "@/lib/knowledge/sources";
import { findKnowledgeValues } from "@/lib/knowledge/values";
import { fitting, MAX_PAGE_TEXT, MAX_TOOL_RESULT, type Tool, type ToolContext } from "./common";

export const KNOWLEDGE_DEFAULT_HITS = 8;
export const KNOWLEDGE_MAX_HITS = 20;

const refOf = (chunkId: number) => `k:${chunkId}`;

/** The turn may use the knowledge base, and its user still may (an editor, the module on): a
 *  turn runs long enough for a role to change. */
export function requireKnowledge(ctx: ToolContext) {
  if (!ctx.knowledge || !ctx.userId || !knowledgeForUser(ctx.db, ctx.familyId, ctx.userId)) {
    throw new HttpError(403, "The knowledge base isn't available in this chat");
  }
}

/** The chunk ids of refs ("k:<id>"). */
const idsOf = (refs: string[]) => [...new Set(refs.map((r) => Number(r.slice(2))))];

function strings(v: unknown, field: string): string[] | undefined {
  if (v === undefined || v === null) return undefined;
  const list = Array.isArray(v) ? v : [v];
  if (list.some((x) => typeof x !== "string")) throw new HttpError(400, `${field} must be a list of strings`);
  return (list as string[]).map((s) => s.trim()).filter(Boolean);
}

/** A value as the model reads it: only the parts it has, with its ref. */
function valueOut(v: KnowledgeValue) {
  return {
    ...(v.group ? { group: v.group } : {}),
    name: v.name,
    value: v.value,
    ...(v.unit ? { unit: v.unit } : {}),
    ...(v.range ? { range: v.range } : {}),
    ...(v.note ? { note: v.note } : {}),
    ...(v.date ? { date: v.date } : {}),
    ref: refOf(v.chunkId),
  };
}

/** Values read_knowledge gives with a document at most (characters of JSON); the rest come from
 *  knowledge_values. */
const MAX_READ_VALUES = 6000;

/** Splits `chunks` into parts of at most `budget` characters of text (each at least one chunk). */
function parts<T extends { text: string }>(chunks: T[], budget: number): T[][] {
  const out: T[][] = [];
  let size = Infinity;
  for (const c of chunks) {
    if (size + c.text.length > budget) {
      out.push([]);
      size = 0;
    }
    out.at(-1)!.push(c);
    size += c.text.length + 40;
  }
  return out;
}

export const knowledgeTools: Record<string, Tool> = {
  search_knowledge: {
    needsKnowledge: true,
    spec: {
      name: "search_knowledge",
      description:
        "Searches the family's documents (contracts, insurance policies, letters, timetables, medical reports, manuals …) for words: their text and their file names, folders, tags, summaries and keywords. The best passages first, each with its ref for the source marker and the document's date (its first passage also with the document's summary, written by the assistant: cite only the passages' text); documents whose name holds the words come first, the newest first. Passages with all words first, else those with the most; word beginnings match (\"versich\" finds \"Versicherung\"), case and accents don't matter. Use a few words in the documents' language (\"Stundenplan\", not a sentence); search again with other words (synonyms) when it finds nothing fitting. When several versions of a document fit (an old and a new timetable or contract), go by the newest unless asked about another.",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string", description: "The words to look for" },
          tags: { type: "array", items: { type: "string" }, description: "Only documents with all these tags" },
          folder: { type: "string", description: "Only documents in this subfolder, e.g. \"Versicherungen/Auto\"" },
          limit: { type: "integer", minimum: 1, maximum: KNOWLEDGE_MAX_HITS, description: `Passages at most (default ${KNOWLEDGE_DEFAULT_HITS})` },
        },
        required: ["query"],
      },
    },
    async run(args, ctx) {
      requireKnowledge(ctx);
      const query = typeof args.query === "string" ? args.query.trim() : "";
      if (!query) throw new HttpError(400, "query is required");
      const limit = args.limit === undefined || args.limit === null ? KNOWLEDGE_DEFAULT_HITS : Number(args.limit);
      if (!Number.isInteger(limit) || limit < 1 || limit > KNOWLEDGE_MAX_HITS) {
        throw new HttpError(400, `limit must be 1–${KNOWLEDGE_MAX_HITS}`);
      }
      const folder = typeof args.folder === "string" ? args.folder.trim().replace(/^\/+|\/+$/g, "") : "";
      const found = searchKnowledge(ctx.db, ctx.familyId, query, { limit, tags: strings(args.tags, "tags"), folder: folder || null });
      // A document's summary comes once, with its first passage.
      const summarized = new Set<string>();
      const hits = found.map((h) => {
        const summary = h.summary && !summarized.has(h.documentId) ? h.summary : null;
        summarized.add(h.documentId);
        return {
          ref: refOf(h.chunkId),
          documentId: h.documentId,
          name: h.name,
          path: h.path,
          page: h.page,
          ...(h.date ? { date: h.date } : {}),
          ...(summary ? { summary } : {}),
          text: h.text,
        };
      });
      const shown = fitting({}, hits);
      return {
        result: {
          hits: shown,
          ...(shown.length < hits.length ? { more: hits.length - shown.length } : {}),
          ...(hits.length ? {} : { note: "Nothing found. Try other words, or say that the documents don't say." }),
        },
        summary: `${hits.length} ${hits.length === 1 ? "hit" : "hits"}`,
        refs: idsOf(shown.map((h) => h.ref)),
      };
    },
  },

  read_knowledge: {
    needsKnowledge: true,
    spec: {
      name: "read_knowledge",
      description:
        "Reads one of the family's documents (by documentId from search_knowledge): its card (summary, date, tags, facts with verbatim quotes and their refs, the values it reports with their refs) and its text in passages with their refs. A short document comes whole; a long one a page at a time (page, from 1; part when a page is longer still).",
      parameters: {
        type: "object",
        properties: {
          documentId: { type: "string" },
          page: { type: "integer", minimum: 1, description: "The page to read (default: the whole text when short, else the first page)" },
          part: { type: "integer", minimum: 1, description: "A part of a very long page (default 1)" },
        },
        required: ["documentId"],
      },
    },
    async run(args, ctx) {
      requireKnowledge(ctx);
      const id = typeof args.documentId === "string" ? args.documentId.trim() : "";
      const row = id ? getDocumentRow(ctx.db, ctx.familyId, id) : null;
      if (!row || row.status === "excluded") throw new HttpError(404, `No document "${id}" in the knowledge base`);
      const chunks = ctx.db
        .select({ id: kbChunks.id, page: kbChunks.page, text: kbChunks.text })
        .from(kbChunks)
        .where(eq(kbChunks.documentId, row.id))
        .orderBy(asc(kbChunks.seq))
        .all()
        .map((c) => ({ ref: refOf(c.id), page: c.page, text: c.text }));
      const facts = (parseJsonArray<KnowledgeFact>(row.facts) ?? []).map((f) => ({
        text: f.text,
        quote: f.quote,
        ref: refOf(f.chunkId),
        page: f.page,
      }));
      const allValues = (parseJsonArray<KnowledgeValue>(row.values) ?? []).map(valueOut);
      const values = fitting({}, allValues, MAX_READ_VALUES);
      const document = {
        id: row.id,
        name: row.name,
        path: row.path,
        tags: parseJsonArray<string>(row.tags) ?? [],
        docDate: row.docDate,
        summary: row.summary,
        ...(row.keywords ? { keywords: parseJsonArray<string>(row.keywords) ?? [] } : {}),
        facts,
        ...(values.length ? { values } : {}),
        ...(values.length < allValues.length
          ? { moreValues: `${allValues.length - values.length} more values: knowledge_values with this documentId` }
          : {}),
        ...(row.status === "ready" ? {} : { status: row.status }),
      };
      // The card's refs (facts and values) count as given with every page.
      const cardRefs = [...facts, ...values];
      const pages = Math.max(row.pages, ...chunks.map((c) => c.page), 0);
      const budget = Math.max(2000, Math.min(MAX_PAGE_TEXT, MAX_TOOL_RESULT - 1500 - JSON.stringify(document).length));
      const total = chunks.reduce((n, c) => n + c.text.length + 40, 0);
      if (!chunks.length) {
        return {
          result: { document, pages, page: null, chunks: [], note: "The document has no text in the knowledge base." },
          summary: row.name,
          refs: idsOf(cardRefs.map((f) => f.ref)),
        };
      }
      if ((args.page === undefined || args.page === null) && total <= budget) {
        return { result: { document, pages, page: null, chunks }, summary: row.name, refs: idsOf([...cardRefs, ...chunks].map((c) => c.ref)) };
      }
      const page = args.page === undefined || args.page === null ? chunks[0].page : Number(args.page);
      if (!Number.isInteger(page) || page < 1 || page > pages) throw new HttpError(400, `page must be 1–${pages}`);
      const onPage = parts(chunks.filter((c) => c.page === page), budget);
      const part = args.part === undefined || args.part === null ? 1 : Number(args.part);
      if (onPage.length && (!Number.isInteger(part) || part < 1 || part > onPage.length)) {
        throw new HttpError(400, `part must be 1–${onPage.length}`);
      }
      const next = chunks.find((c) => c.page > page)?.page ?? null;
      return {
        result: {
          document,
          pages,
          page,
          ...(onPage.length > 1 ? { part, parts: onPage.length } : {}),
          chunks: onPage[part - 1] ?? [],
          ...(onPage.length ? {} : { note: `Page ${page} has no text.` }),
          // Where reading goes on: the page's next part, else the next page with text.
          next: part < onPage.length ? { page, part: part + 1 } : next ? { page: next } : null,
        },
        summary: `${row.name}, p. ${page}${onPage.length > 1 ? ` (${part}/${onPage.length})` : ""}`,
        refs: idsOf([...cardRefs, ...(onPage[part - 1] ?? [])].map((c) => c.ref)),
      };
    },
  },

  knowledge_values: {
    needsKnowledge: true,
    spec: {
      name: "knowledge_values",
      description:
        "Lists the values the family's documents report, as the documents write them: lab and test results, measurements and readings, grades, scores, the figures of statements and reports. Across documents and over time, oldest first (e.g. every \"Hämoglobin\" of the blood tests, a child's grades over the school years), each with its document, day (its own, else the document's), person, group, unit, reference range, note and its ref for the source marker. Use it for how a value developed, for comparisons, and for all values of a report (documentId). Names are in the documents' language; search with a word beginning (\"hämo\", \"mathe\"); without query, all of them.",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string", description: "Words that begin words of the value's name or group (e.g. \"Cholesterin\", \"Mathe\")" },
          documentId: { type: "string", description: "Only this document's values" },
          person: { type: "string", description: "Only documents of this family member (their name)" },
          from: { type: "string", description: "YYYY-MM-DD: values of this day or later" },
          to: { type: "string", description: "YYYY-MM-DD: values of this day or earlier" },
        },
      },
    },
    async run(args, ctx) {
      requireKnowledge(ctx);
      const text = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : null);
      const date = (v: unknown, field: string) => {
        const d = text(v);
        if (d && !isValidDate(d)) throw new HttpError(400, `${field} must be YYYY-MM-DD`);
        return d;
      };
      let personId: string | null = null;
      const person = text(args.person);
      if (person) {
        const found = matchPerson(person, familyNames(ctx.db, ctx.familyId).map(({ id, name, account }) => ({ id, name, account })));
        if (!found) throw new HttpError(400, `No family member "${person}"`);
        personId = found.id;
      }
      const hits = findKnowledgeValues(ctx.db, ctx.familyId, {
        query: text(args.query),
        documentId: text(args.documentId),
        personId,
        from: date(args.from, "from"),
        to: date(args.to, "to"),
      });
      const rows = hits.map((h) => ({
        documentId: h.documentId,
        document: h.documentName,
        ...(h.day ? { day: h.day } : {}),
        ...(h.person ? { person: h.person } : {}),
        ...valueOut({ ...h, date: null }),
      }));
      const shown = fitting({}, rows);
      return {
        result: {
          values: shown,
          ...(shown.length < rows.length ? { more: rows.length - shown.length, note: "Narrow it down with query, documentId, person or from / to." } : {}),
          ...(rows.length
            ? {}
            : { note: "No values found. Try another word, or search_knowledge: a document's card may not be written yet." }),
        },
        summary: `${rows.length} ${rows.length === 1 ? "value" : "values"}`,
        refs: idsOf(shown.map((r) => r.ref)),
      };
    },
  },
};
