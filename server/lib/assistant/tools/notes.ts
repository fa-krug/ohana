// The assistant's notes tool (module knowledge): the family's notes are Markdown (or text) files
// in its knowledge folder, which lives on the user's devices (iCloud Drive); the server only
// keeps the index of their text. So edit_knowledge_notes works like edit_reminders
// (reminders.ts): it checks its ops against the index and then ends the step: the chat shows the
// changes as a card (`kind: "notes"`), the app writes the files into the folder once the user
// says so and answers (POST /ai/chats/{id}/notes), and that answer is the tool's result.
// Offered only to editors whose app has the family's folder linked (`knowledgeFolder` in the
// chat's context, ToolContext.knowledgeFolder), with changes allowed.

import { and, eq } from "drizzle-orm";
import { HttpError } from "@/lib/api/http";
import type { Db } from "@/lib/db";
import { kbDocuments } from "@/lib/db/schema";
import { type DocumentRow, parseJsonArray } from "@/lib/knowledge/documents";
import { getFolder } from "@/lib/knowledge/folders";
import { cleanPath, cleanTags, nameOf, normalizePath } from "@/lib/knowledge/input";
import { opsSummary, type Tool, type ToolContext } from "./common";
import { requireKnowledge } from "./knowledge";

/** One change of an edit, resolved: a new note, or a note of the index changed (the whole new
 *  text in `content`, checked against the file by `baseHash` before it is written). */
export type NoteOp =
  | { op: "create"; path: string; title: string; content: string; tags?: string[] }
  | {
      op: "update";
      documentId: string;
      path: string;
      /** The file's name, e.g. "Car.md". */
      title: string;
      /** The document's stored SHA-256: the file the server read. */
      baseHash: string;
      /** What the call asked for ("tags" only when nothing but tags). */
      change: NoteChange;
      /** The whole new text (for "tags" the current text, not to be written). */
      content: string;
      /** append: the text added, for the card. */
      added?: string;
      /** replace: the passages replaced, for the card. */
      replacements?: { find: string; with: string }[];
      /** Replaces the file's Finder tags when present. */
      tags?: string[];
    };

export type NoteChange = "content" | "append" | "replace" | "tags";
type UpdateOp = NoteOp & { op: "update" };

/** A change of the family's notes, waiting for the user's OK in the app. */
export interface NotesEdit {
  summary: string;
  ops: NoteOp[];
}

export const MAX_NOTE_OPS = 10;
/** Characters of a note's text (new or changed). */
export const MAX_NOTE_CONTENT = 50_000;
/** Bytes of a file that can be changed here. */
export const MAX_NOTE_BYTES = 200_000;
export const MAX_REPLACEMENTS = 20;

/** A document of the index as the tool sees it. */
export interface NoteDocument {
  id: string;
  path: string;
  name: string;
  hash: string;
  size: number;
  status: string;
  /** The stored pages of text (null: none readable). */
  pages: string[] | null;
}

/** Finds the folder's documents, by id or by path. */
export interface NoteIndex {
  byId(id: string): NoteDocument | null;
  byPath(path: string): NoteDocument | null;
}

function noteDocument(row: DocumentRow | undefined): NoteDocument | null {
  if (!row) return null;
  const pages = parseJsonArray<unknown>(row.text);
  return {
    id: row.id,
    path: row.path,
    name: row.name,
    hash: row.hash,
    size: row.size,
    status: row.status,
    pages: pages && pages.every((p) => typeof p === "string") ? (pages as string[]) : null,
  };
}

/** The index of the family's folder `folderId`. */
export function noteIndex(db: Db, familyId: string, folderId: string): NoteIndex {
  const inFolder = and(eq(kbDocuments.familyId, familyId), eq(kbDocuments.folderId, folderId));
  return {
    byId: (id) => noteDocument(db.select().from(kbDocuments).where(and(inFolder, eq(kbDocuments.id, id))).get()),
    byPath: (path) => noteDocument(db.select().from(kbDocuments).where(and(inFolder, eq(kbDocuments.path, path))).get()),
  };
}

const NOTE_NAME = /\.(md|markdown|txt)$/i;

/** A path the model gave: spaces and slashes around it are ignored. */
const trimmedPath = (v: unknown) => (typeof v === "string" ? v.trim().replace(/^\/+|\/+$/g, "") : "");

/** A new note's path: inside the folder, ending in ".md". */
function createPath(v: unknown): string {
  const path = cleanPath(trimmedPath(v));
  return /\.md$/i.test(nameOf(path)) ? path : cleanPath(`${path}.md`);
}

function textArg(v: unknown, field: string): string {
  if (typeof v !== "string") throw new HttpError(400, `${field} must be text`);
  if (!v.trim()) throw new HttpError(400, `${field} must not be empty`);
  if (v.length > MAX_NOTE_CONTENT) throw new HttpError(400, `${field} takes at most ${MAX_NOTE_CONTENT} characters`);
  return v;
}

const tagsArg = (v: unknown) => (v === undefined || v === null ? undefined : cleanTags(v));

/** The note an update names (documentId, else path), with its one page of text. */
function findNote(index: NoteIndex, o: Record<string, unknown>): { doc: NoteDocument; text: string } {
  const id = typeof o.documentId === "string" ? o.documentId.trim() : "";
  const path = id ? "" : trimmedPath(o.path);
  if (!id && !path) throw new HttpError(400, "documentId or path is required");
  const found = id ? index.byId(id) : normalizePath(path) && index.byPath(normalizePath(path)!);
  if (!found || found.status === "missing" || found.status === "excluded") {
    throw new HttpError(404, `No note "${id || path}" in the knowledge folder (search_knowledge gives the documentIds)`);
  }
  if (!NOTE_NAME.test(found.name)) throw new HttpError(400, "Only Markdown and text notes can be edited");
  const pages = found.pages ?? [];
  if (!pages.length) throw new HttpError(400, "The note's text isn't read yet: it can't be edited before");
  if (pages.length > 1) throw new HttpError(400, "The note has several pages: it can't be edited here");
  if (found.size > MAX_NOTE_BYTES || pages[0].length > MAX_NOTE_CONTENT) throw new HttpError(400, "The note is too long to edit here");
  return { doc: found, text: pages[0] };
}

/** How often `find` occurs in `text` (overlapping ones too: it must be unique). */
function occurrences(text: string, find: string): number {
  let n = 0;
  for (let i = text.indexOf(find); i >= 0; i = text.indexOf(find, i + 1)) n++;
  return n;
}

const quoted = (s: string) => `“${s.length > 80 ? `${s.slice(0, 80)}…` : s}”`;

/** The text with each passage replaced, in order; each must occur exactly once at its turn. */
function replaced(text: string, raw: unknown): { text: string; replacements: { find: string; with: string }[] } {
  if (!Array.isArray(raw) || !raw.length || raw.length > MAX_REPLACEMENTS) {
    throw new HttpError(400, `replace must be a list of 1 to ${MAX_REPLACEMENTS} {find, with}`);
  }
  const replacements: { find: string; with: string }[] = [];
  for (const [j, r] of raw.entries()) {
    const o = (r && typeof r === "object" ? r : {}) as Record<string, unknown>;
    if (typeof o.find !== "string" || !o.find) throw new HttpError(400, `replace[${j}].find must not be empty`);
    if (typeof o.with !== "string") throw new HttpError(400, `replace[${j}].with must be text`);
    const n = occurrences(text, o.find);
    if (!n) throw new HttpError(400, `replace[${j}]: ${quoted(o.find)} not found`);
    if (n > 1) throw new HttpError(400, `replace[${j}]: ${quoted(o.find)} found ${n} times: give more of the text`);
    const at = text.indexOf(o.find);
    text = text.slice(0, at) + o.with + text.slice(at + o.find.length);
    replacements.push({ find: o.find, with: o.with });
  }
  return { text, replacements };
}

/** The change of two updates of one note in one call. */
const mergedChange = (a: NoteChange, b: NoteChange): NoteChange => (a === "tags" ? b : b === "tags" || a === b ? a : "content");

/** The ops of edit_knowledge_notes, checked against the index and resolved. Updates of one note
 *  build on each other and become one op (where the first was). */
export function resolveNoteOps(index: NoteIndex, raw: unknown): NoteOp[] {
  if (!Array.isArray(raw) || !raw.length || raw.length > MAX_NOTE_OPS) {
    throw new HttpError(400, `ops must be a list of 1 to ${MAX_NOTE_OPS} changes`);
  }
  const out: NoteOp[] = [];
  const created = new Set<string>();
  const updates = new Map<string, UpdateOp>();
  for (const [i, rawOp] of raw.entries()) {
    const o = (rawOp && typeof rawOp === "object" ? rawOp : {}) as Record<string, unknown>;
    try {
      switch (o.op) {
        case "create": {
          const path = createPath(o.path);
          const existing = index.byPath(path);
          if (created.has(path) || (existing && existing.status !== "missing")) {
            throw new HttpError(409, `"${path}" already exists: update it instead`);
          }
          created.add(path);
          const content = textArg(o.content, "content");
          const tags = tagsArg(o.tags);
          out.push({ op: "create", path, title: nameOf(path), content, ...(tags?.length ? { tags } : {}) });
          break;
        }
        case "update": {
          const { doc, text: stored } = findNote(index, o);
          const prev = updates.get(doc.id);
          const current = prev ? prev.content : stored;
          const asked = (["content", "append", "replace"] as const).filter((k) => o[k] !== undefined && o[k] !== null);
          if (asked.length > 1) throw new HttpError(400, "give only one of content, append or replace");
          const tags = tagsArg(o.tags);
          if (!asked.length && !tags) throw new HttpError(400, "update changes nothing: give content, append, replace or tags");
          const change: NoteChange = asked.length ? asked[0] : "tags";
          let next = current;
          let added: string | undefined;
          let replacements: { find: string; with: string }[] | undefined;
          if (change === "content") next = textArg(o.content, "content");
          if (change === "append") {
            added = textArg(o.append, "append").trimEnd();
            next = current.trim() ? `${current.trimEnd()}\n\n${added}\n` : `${added}\n`;
          }
          if (change === "replace") ({ text: next, replacements } = replaced(current, o.replace));
          if (next.length > MAX_NOTE_CONTENT) {
            throw new HttpError(400, `the note would be too long (max. ${MAX_NOTE_CONTENT} characters)`);
          }
          if (change !== "tags" && next === current && !tags) throw new HttpError(400, "update changes nothing: the text stays the same");
          if (prev) {
            prev.change = mergedChange(prev.change, change);
            prev.content = next;
            if (added !== undefined) prev.added = prev.added ? `${prev.added}\n\n${added}` : added;
            if (replacements) prev.replacements = [...(prev.replacements ?? []), ...replacements];
            if (tags) prev.tags = tags;
            break;
          }
          const op: UpdateOp = {
            op: "update",
            documentId: doc.id,
            path: doc.path,
            title: nameOf(doc.path),
            baseHash: doc.hash,
            change,
            content: next,
            ...(added !== undefined ? { added } : {}),
            ...(replacements ? { replacements } : {}),
            ...(tags ? { tags } : {}),
          };
          updates.set(doc.id, op);
          out.push(op);
          break;
        }
        default:
          throw new HttpError(400, "op must be create or update");
      }
    } catch (err) {
      if (err instanceof HttpError) throw new HttpError(err.status, `ops[${i}]: ${err.message}`);
      throw err;
    }
  }
  return out;
}

/** The folder a note is in ("" for the knowledge folder itself). */
const folderOf = (path: string) => path.slice(0, Math.max(0, path.lastIndexOf("/")));

/** What the card says the edit does, e.g. "Create “Car.md”", "Create 2 notes, change 1 note". */
export function notesEditSummary(ops: NoteOp[], lang: "en" | "de"): string {
  return opsSummary(ops, lang, {
    noun: { en: ["note", "notes"], de: ["Notiz", "Notizen"] },
    verbs: [
      ["create", "create", "anlegen"],
      ["update", "change", "ändern"],
    ],
    name: (o) => o.title,
    target: (o) => {
      const folder = folderOf(o.path);
      return { id: folder, title: folder || (lang === "de" ? "Wissen" : "Knowledge") };
    },
  });
}

export const noteTools: Record<string, Tool> = {
  edit_knowledge_notes: {
    write: true,
    needsKnowledge: true,
    needsKnowledgeNotes: true,
    spec: {
      name: "edit_knowledge_notes",
      description:
        'Creates or changes the family\'s notes: Markdown (or text) files in its knowledge folder. Nothing changes right away: the app shows the changes and the user applies or declines them. The result comes back as this tool\'s result: {"applied": true, "results": [{"ok": true, "id": "<path>"} | {"ok": false, "error": "…"}, …] (one per op, in order)}, {"applied": false} when they declined, or {"skipped": true} when they wrote a new message instead. Put all changes into one call; call no other tools after it in the same step, and don\'t ask a question (ask_user) in the same step. ops, in order: {"op": "create", "path": "Notes/Car.md" (".md" is added when missing), "content": Markdown, "tags"?: Finder tags}; {"op": "update", "documentId" (from search_knowledge / read_knowledge) or "path", then one of "content" (the whole new text), "append" (added at the end) or "replace": [{"find": a passage exactly as in the note, once, "with": its new text}], and/or "tags" (replace the file\'s tags)}. Only .md, .markdown and .txt notes can be changed; read one before you change it.',
      parameters: {
        type: "object",
        properties: {
          ops: {
            type: "array",
            description: `1 to ${MAX_NOTE_OPS} changes, applied in order.`,
            items: {
              type: "object",
              properties: {
                op: { type: "string", enum: ["create", "update"] },
                path: { type: "string", description: 'A path in the knowledge folder, e.g. "Notes/Car.md"' },
                documentId: { type: "string", description: "The note to change (update)" },
                content: { type: "string", description: "create: the note's text; update: its whole new text" },
                append: { type: "string", description: "update: text to add at the end" },
                replace: {
                  type: "array",
                  description: "update: passages to replace, each occurring exactly once",
                  items: {
                    type: "object",
                    properties: { find: { type: "string" }, with: { type: "string" } },
                    required: ["find", "with"],
                  },
                },
                tags: { type: "array", items: { type: "string" }, description: "The file's Finder tags" },
              },
              required: ["op"],
            },
          },
        },
        required: ["ops"],
      },
    },
    run(args, ctx) {
      const folderId = notesFolderOf(ctx);
      const ops = resolveNoteOps(noteIndex(ctx.db, ctx.familyId, folderId), args.ops);
      const summary = notesEditSummary(ops, ctx.lang);
      return Promise.resolve({ result: { waiting: true }, summary, notes: { summary, ops } });
    },
  },
};

/** The folder notes go into: the chat's, while the user may still use the knowledge base and
 *  it still is the family's. */
function notesFolderOf(ctx: ToolContext): string {
  requireKnowledge(ctx);
  if (!ctx.knowledgeFolder) throw new HttpError(403, "Notes can't be written from this chat");
  if (getFolder(ctx.db, ctx.familyId)?.id !== ctx.knowledgeFolder) throw new HttpError(409, "The knowledge folder changed");
  return ctx.knowledgeFolder;
}
