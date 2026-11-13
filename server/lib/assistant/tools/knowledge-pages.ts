// view_knowledge_pages (module knowledge): the assistant looks at a document's pages themselves,
// not only at the text read from them: a chart, handwriting, a stamp, a form's layout. The server
// never holds the family's files; the app does (the knowledge folder linked on the device). So
// the tool works like edit_knowledge_notes (notes.ts): it checks the document and the pages and
// ends the step with a `kind: "pages"` item; the app renders the pages as JPEGs, uploads each
// (PUT /ai/chats/{id}/pages?call=&page=) and answers (POST /ai/chats/{id}/pages), and the turn
// goes on with the pages as images (page-images.ts). With the family's *Read with the assistant*
// (`kb_folders.ai_scans`) on, the app sends them right away (`auto`); else it asks first.
// Offered only to editors whose app has the family's folder linked (ToolContext.knowledgeFolder);
// it changes nothing, so also with changes off.

import { HttpError } from "@/lib/api/http";
import { getDocumentRow } from "@/lib/knowledge/documents";
import { getFolder } from "@/lib/knowledge/folders";
import { nameOf } from "@/lib/knowledge/input";
import { DEFAULT_WINDOW } from "../context";
import type { Tool, ToolContext } from "./common";
import { requireKnowledge } from "./knowledge";

/** Pages one call sends at most (the server's limit: a page is about a thousand tokens or more). */
export const MAX_VIEW_PAGES = 30;
/** Tokens a page costs the model, roughly (a page image of up to 1600 px). */
const PAGE_TOKENS = 1500;
/** The share of the context window one call's pages may take. */
const PAGES_SHARE = 0.3;

/** The files the app can show as pages: PDFs (a page each) and images (one page). */
const VIEWABLE = /\.(pdf|jpe?g|png|heic|heif|tiff?)$/i;

/** A document's pages the assistant asked to see, waiting for the app. */
export interface PagesRequest {
  summary: string;
  documentId: string;
  /** The file's name and path in the knowledge folder, as the index has them. */
  name: string;
  path: string;
  /** The document's SHA-256 as indexed (the version the text and page numbers come from). */
  hash: string;
  /** The pages to send (from 1), in order. */
  pages: number[];
  /** The document's pages as the index knows them (0: not known yet). */
  total: number;
  /** The family's *Read with the assistant* is on: the app sends them without asking. */
  auto: boolean;
}

/** Pages one call may send in a context window of `window` tokens. */
export function pagesFor(window: number | undefined): number {
  return Math.max(1, Math.min(MAX_VIEW_PAGES, Math.floor(((window || DEFAULT_WINDOW) * PAGES_SHARE) / PAGE_TOKENS)));
}

/** The pages asked for: a list of page numbers or "from-to" ranges; none: every page (as many as
 *  fit). Checked against the document's `total` pages when it is known. */
export function resolvePages(raw: unknown, total: number, max: number): number[] {
  if (raw === undefined || raw === null || (Array.isArray(raw) && !raw.length)) {
    const count = total > 0 ? Math.min(total, max) : max;
    return Array.from({ length: count }, (_, i) => i + 1);
  }
  const list = Array.isArray(raw) ? raw : [raw];
  const out = new Set<number>();
  for (const v of list) {
    const m = typeof v === "string" ? /^\s*(\d+)\s*(?:[-–]\s*(\d+)\s*)?$/.exec(v) : null;
    const from = typeof v === "number" ? v : m ? Number(m[1]) : NaN;
    const to = typeof v === "number" ? v : m?.[2] ? Number(m[2]) : from;
    if (!Number.isInteger(from) || !Number.isInteger(to) || from < 1 || to < from) {
      throw new HttpError(400, 'pages must be page numbers (from 1) or ranges like "3-5"');
    }
    if (total > 0 && to > total) throw new HttpError(400, `The document has ${total} page${total === 1 ? "" : "s"}`);
    for (let p = from; p <= to; p++) {
      out.add(p);
      if (out.size > max) throw new HttpError(400, `At most ${max} pages at a time: ask for the rest in another call`);
    }
  }
  return [...out].sort((a, b) => a - b);
}

/** "pages 1–3, 7" */
export function pagesText(pages: number[]): string {
  const runs: string[] = [];
  for (let i = 0; i < pages.length;) {
    let j = i;
    while (j + 1 < pages.length && pages[j + 1] === pages[j] + 1) j++;
    runs.push(j > i ? `${pages[i]}–${pages[j]}` : `${pages[i]}`);
    i = j + 1;
  }
  return runs.join(", ");
}

/** What the card says, e.g. "Look at pages 1–4 of “Befund.pdf”". */
export function pagesSummary(name: string, pages: number[], total: number, lang: "en" | "de"): string {
  const all = total > 0 && pages.length === total;
  if (lang === "de") {
    if (all) return total === 1 ? `„${name}“ ansehen` : `Alle ${total} Seiten von „${name}“ ansehen`;
    return `${pages.length === 1 ? "Seite" : "Seiten"} ${pagesText(pages)} von „${name}“ ansehen`;
  }
  if (all) return total === 1 ? `Look at “${name}”` : `Look at all ${total} pages of “${name}”`;
  return `Look at ${pages.length === 1 ? "page" : "pages"} ${pagesText(pages)} of “${name}”`;
}

/** The chat's folder, while the user may still use the knowledge base and it still is the family's. */
function folderOf(ctx: ToolContext) {
  requireKnowledge(ctx);
  if (!ctx.knowledgeFolder) throw new HttpError(403, "The documents' files aren't on this device");
  const folder = getFolder(ctx.db, ctx.familyId);
  if (folder?.id !== ctx.knowledgeFolder) throw new HttpError(409, "The knowledge folder changed");
  return folder;
}

export const knowledgePageTools: Record<string, Tool> = {
  view_knowledge_pages: {
    needsKnowledge: true,
    needsKnowledgeNotes: true,
    waits: true,
    spec: {
      name: "view_knowledge_pages",
      description:
        `Looks at pages of a PDF or image in the knowledge base as pictures: for what its text doesn't hold or read_knowledge got wrong (charts, tables, handwriting, stamps, signatures, a form's layout, photos). The user's device sends the pages (it may ask the user first), and they come to you as images in the next message; this tool's result says which pages came (or why none did). Give the documentId (from search_knowledge / read_knowledge) and the pages; without pages, every page is sent (at most ${MAX_VIEW_PAGES}, fewer for a small context window; the result says which pages are left). Costs far more than read_knowledge: read the text first, and ask only for the pages you need. Call no other tools in the same step.`,
      parameters: {
        type: "object",
        properties: {
          documentId: { type: "string" },
          pages: {
            type: "array",
            items: { type: "string" },
            description: 'Pages from 1: "2", or ranges like "3-5"; omit for all pages',
          },
        },
        required: ["documentId"],
      },
    },
    run(args, ctx) {
      const folder = folderOf(ctx);
      const id = typeof args.documentId === "string" ? args.documentId.trim() : "";
      const row = id ? getDocumentRow(ctx.db, ctx.familyId, id) : null;
      if (!row || row.folderId !== folder.id || row.status === "excluded") {
        throw new HttpError(404, `No document "${id}" in the knowledge base`);
      }
      if (row.status === "missing") throw new HttpError(404, "The document's file isn't in the knowledge folder any more");
      if (!VIEWABLE.test(row.name)) {
        throw new HttpError(400, "Only PDFs and images can be looked at as pages: use read_knowledge for this document");
      }
      const total = /\.pdf$/i.test(row.name) ? row.pages : 1;
      const pages = resolvePages(args.pages, total, pagesFor(ctx.contextWindow));
      const name = nameOf(row.path);
      const summary = pagesSummary(name, pages, total, ctx.lang);
      return Promise.resolve({
        result: { waiting: true },
        summary,
        pages: { summary, documentId: row.id, name, path: row.path, hash: row.hash, pages, total, auto: folder.aiScans },
      });
    },
  },
};
