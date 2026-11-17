// The assistant's notes tool (lib/assistant/tools/notes.ts): edit_knowledge_notes creates and
// changes Markdown notes in the family's knowledge folder. The files live on the user's devices,
// so it waits for the user like edit_reminders: the app writes them and answers (POST …/notes).
// Offered only to editors with changes on whose app has the family's folder linked
// (`knowledgeFolder` in the chat's context).

import { createHash, randomUUID } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import { cleanContext } from "@/lib/assistant/chat";
import type { NetOptions } from "@/lib/assistant/net";
import { runTool, type ToolContext, TOOLS, toolsFor } from "@/lib/assistant/tools";
import {
  MAX_NOTE_CONTENT,
  type NoteDocument,
  type NoteIndex,
  noteIndex,
  notesEditSummary,
  resolveNoteOps,
} from "@/lib/assistant/tools/notes";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import type { Db } from "@/lib/db";
import { kbDocuments } from "@/lib/db/schema";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { ensureFolder, replaceFolder } from "@/lib/knowledge/folders";
import { type AssistantTest, assistantTest, configure, net } from "@/lib/test/assistant";
import { NOW } from "@/lib/test/factories";

let current: AssistantTest[] = [];
afterEach(async () => {
  await Promise.all(current.map((t) => t.stop()));
  current = [];
  delete process.env.DISABLED_MODULES;
});

const CONTEXT = { today: "2026-11-02", year: 2026, lang: "en", page: "overview" };
const CAR = "# Car\n\nOil: 5W-30\nTyres: summer\n";
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Res = { ok: boolean; result: any; summary: string; notes?: any };

const doc = (d: Partial<NoteDocument> & { id: string; path: string }): NoteDocument => ({
  name: d.path.split("/").at(-1)!,
  hash: `hash-${d.id}`,
  size: 100,
  status: "ready",
  pages: [CAR],
  ...d,
});

const DOCS: NoteDocument[] = [
  doc({ id: "d-car", path: "Notes/Car.md" }),
  doc({ id: "d-shop", path: "Shopping.txt", pages: ["milk\nbread\nmilk\n"] }),
  doc({ id: "d-empty", path: "Notes/Empty.markdown", pages: [""] }),
  doc({ id: "d-pdf", path: "Policy.pdf" }),
  doc({ id: "d-gone", path: "Notes/Old.md", status: "missing" }),
  doc({ id: "d-out", path: "Notes/Out.md", status: "excluded" }),
  doc({ id: "d-big", path: "Notes/Big.md", size: 300_000 }),
  doc({ id: "d-two", path: "Notes/Two.md", pages: ["a", "b"] }),
  doc({ id: "d-unread", path: "Notes/Unread.md", pages: [] }),
];
const INDEX: NoteIndex = {
  byId: (id) => DOCS.find((d) => d.id === id) ?? null,
  byPath: (path) => DOCS.find((d) => d.path === path) ?? null,
};

const resolve = (ops: unknown) => resolveNoteOps(INDEX, ops);
const err = (ops: unknown) => {
  try {
    resolve(ops);
  } catch (e) {
    return `${(e as { status?: number }).status} ${(e as Error).message}`;
  }
  return "ok";
};

describe("edit_knowledge_notes: resolving the ops", () => {
  it("creates notes: the path cleaned, .md added, tags checked", () => {
    expect(
      resolve([
        { op: "create", path: " /Notes/Car wash/ ", content: "# Car wash\n", tags: [" Auto ", "Auto", ""] },
        { op: "create", path: "Todo.MD", content: "- one" },
        { op: "create", path: "Notes/Old.md", content: "A missing document's path is free" },
      ]),
    ).toEqual([
      { op: "create", path: "Notes/Car wash.md", title: "Car wash.md", content: "# Car wash\n", tags: ["Auto"] },
      { op: "create", path: "Todo.MD", title: "Todo.MD", content: "- one" },
      { op: "create", path: "Notes/Old.md", title: "Old.md", content: "A missing document's path is free" },
    ]);
    expect(resolve([{ op: "create", path: "Ideas.txt", content: "x" }])[0]).toMatchObject({ path: "Ideas.txt.md" });
    expect(err([{ op: "create", path: "../x.md", content: "x" }])).toBe("400 ops[0]: path must be a path inside the folder");
    expect(err([{ op: "create", path: "Notes/.hidden.md", content: "x" }])).toMatch(/path must be a path inside the folder/);
    expect(err([{ op: "create", content: "x" }])).toMatch(/path must be a path inside the folder/);
    expect(err([{ op: "create", path: "a.md", content: "  \n" }])).toBe("400 ops[0]: content must not be empty");
    expect(err([{ op: "create", path: "a.md" }])).toBe("400 ops[0]: content must be text");
    expect(err([{ op: "create", path: "a.md", content: "x", tags: "Auto" }])).toMatch(/tags must be a list of strings/);
  });

  it("refuses to create what exists", () => {
    expect(err([{ op: "create", path: "Notes/Car.md", content: "x" }])).toBe('409 ops[0]: "Notes/Car.md" already exists: update it instead');
    expect(err([{ op: "create", path: "Notes/Car", content: "x" }])).toMatch(/^409 ops\[0\]: "Notes\/Car.md" already exists/);
    // An excluded document is still there.
    expect(err([{ op: "create", path: "Notes/Out.md", content: "x" }])).toMatch(/^409 /);
    expect(
      err([
        { op: "create", path: "New.md", content: "x" },
        { op: "create", path: "New", content: "y" },
      ]),
    ).toBe('409 ops[1]: "New.md" already exists: update it instead');
  });

  it("changes a note by id or path: content, append, replace, tags", () => {
    const base = { op: "update", documentId: "d-car", path: "Notes/Car.md", title: "Car.md", baseHash: "hash-d-car" };
    expect(resolve([{ op: "update", documentId: "d-car", content: "# Car\n\nSold.\n" }])).toEqual([
      { ...base, change: "content", content: "# Car\n\nSold.\n" },
    ]);
    expect(resolve([{ op: "update", path: "/Notes/Car.md", append: "Inspection: May 2027  \n\n" }])).toEqual([
      { ...base, change: "append", content: `${CAR.trimEnd()}\n\nInspection: May 2027\n`, added: "Inspection: May 2027" },
    ]);
    expect(resolve([{ op: "update", documentId: "d-empty", append: "First line" }])[0]).toMatchObject({
      change: "append",
      content: "First line\n",
      added: "First line",
    });
    expect(
      resolve([
        {
          op: "update",
          documentId: "d-car",
          replace: [
            { find: "5W-30", with: "0W-20" },
            { find: "Tyres: summer", with: "Tyres: winter" },
          ],
        },
      ]),
    ).toEqual([
      {
        ...base,
        change: "replace",
        content: "# Car\n\nOil: 0W-20\nTyres: winter\n",
        replacements: [
          { find: "5W-30", with: "0W-20" },
          { find: "Tyres: summer", with: "Tyres: winter" },
        ],
      },
    ]);
    // Only the tags: the text stays (sent for the card, not written).
    expect(resolve([{ op: "update", documentId: "d-car", tags: ["Auto", "Wartung"] }])).toEqual([
      { ...base, change: "tags", content: CAR, tags: ["Auto", "Wartung"] },
    ]);
    // Text and tags together; a text note too.
    expect(resolve([{ op: "update", path: "Shopping.txt", replace: [{ find: "bread", with: "rolls" }], tags: [] }])[0]).toMatchObject({
      title: "Shopping.txt",
      change: "replace",
      content: "milk\nrolls\nmilk\n",
      tags: [],
    });
  });

  it("refuses changes that don't fit", () => {
    expect(err([{ op: "update", documentId: "nope", append: "x" }])).toBe(
      '404 ops[0]: No note "nope" in the knowledge folder (search_knowledge gives the documentIds)',
    );
    expect(err([{ op: "update", path: "Notes/Old.md", append: "x" }])).toMatch(/^404 /);
    expect(err([{ op: "update", documentId: "d-out", append: "x" }])).toMatch(/^404 /);
    expect(err([{ op: "update", path: "../Car.md", append: "x" }])).toMatch(/^404 /);
    expect(err([{ op: "update", append: "x" }])).toBe("400 ops[0]: documentId or path is required");
    expect(err([{ op: "update", documentId: "d-pdf", append: "x" }])).toBe("400 ops[0]: Only Markdown and text notes can be edited");
    expect(err([{ op: "update", documentId: "d-big", append: "x" }])).toBe("400 ops[0]: The note is too long to edit here");
    expect(err([{ op: "update", documentId: "d-two", append: "x" }])).toMatch(/^400 ops\[0\]: The note has several pages/);
    expect(err([{ op: "update", documentId: "d-unread", append: "x" }])).toMatch(/^400 ops\[0\]: The note's text isn't read yet/);
    expect(err([{ op: "update", documentId: "d-car" }])).toMatch(/^400 ops\[0\]: update changes nothing/);
    expect(err([{ op: "update", documentId: "d-car", content: CAR }])).toMatch(/^400 ops\[0\]: update changes nothing/);
    expect(err([{ op: "update", documentId: "d-car", content: "x", append: "y" }])).toBe(
      "400 ops[0]: give only one of content, append or replace",
    );
    expect(err([{ op: "update", documentId: "d-car", append: " " }])).toBe("400 ops[0]: append must not be empty");
    expect(err([{ op: "update", documentId: "d-car", replace: [{ find: "Diesel", with: "x" }] }])).toBe(
      "400 ops[0]: replace[0]: “Diesel” not found",
    );
    expect(err([{ op: "update", path: "Shopping.txt", replace: [{ find: "milk", with: "oat milk" }] }])).toBe(
      "400 ops[0]: replace[0]: “milk” found 2 times: give more of the text",
    );
    expect(err([{ op: "update", documentId: "d-car", replace: [{ find: "", with: "x" }] }])).toMatch(/replace\[0\].find must not be empty/);
    expect(err([{ op: "update", documentId: "d-car", replace: [{ find: "Car" }] }])).toMatch(/replace\[0\].with must be text/);
    expect(err([{ op: "update", documentId: "d-car", replace: [] }])).toMatch(/replace must be a list of 1 to 20/);
    expect(err([{ op: "delete", documentId: "d-car" }])).toBe("400 ops[0]: op must be create or update");
  });

  it("keeps to the limits", () => {
    expect(err([])).toMatch(/ops must be a list of 1 to 10 changes/);
    expect(err("x")).toMatch(/ops must be a list/);
    expect(err(Array.from({ length: 11 }, (_, i) => ({ op: "create", path: `n${i}.md`, content: "x" })))).toMatch(/1 to 10/);
    expect(resolve(Array.from({ length: 10 }, (_, i) => ({ op: "create", path: `n${i}.md`, content: "x" })))).toHaveLength(10);
    expect(err([{ op: "create", path: "a.md", content: "x".repeat(MAX_NOTE_CONTENT + 1) }])).toMatch(/content takes at most 50000/);
    expect(resolve([{ op: "create", path: "a.md", content: "x".repeat(MAX_NOTE_CONTENT) }])).toHaveLength(1);
    expect(err([{ op: "update", documentId: "d-car", append: "x".repeat(MAX_NOTE_CONTENT - 10) }])).toMatch(
      /the note would be too long \(max. 50000 characters\)/,
    );
    const many = Array.from({ length: 21 }, () => ({ find: "Car", with: "Car" }));
    expect(err([{ op: "update", documentId: "d-car", replace: many }])).toMatch(/1 to 20/);
  });

  it("merges the changes of one note into one op, each built on the one before", () => {
    const ops = resolve([
      { op: "update", documentId: "d-car", append: "Inspection: May 2027" },
      { op: "create", path: "Notes/Bike.md", content: "# Bike" },
      { op: "update", path: "Notes/Car.md", replace: [{ find: "May 2027", with: "June 2027" }], tags: ["Auto"] },
    ]);
    expect(ops).toEqual([
      {
        op: "update",
        documentId: "d-car",
        path: "Notes/Car.md",
        title: "Car.md",
        baseHash: "hash-d-car",
        change: "content",
        content: `${CAR.trimEnd()}\n\nInspection: June 2027\n`,
        added: "Inspection: May 2027",
        replacements: [{ find: "May 2027", with: "June 2027" }],
        tags: ["Auto"],
      },
      { op: "create", path: "Notes/Bike.md", title: "Bike.md", content: "# Bike" },
    ]);
    // Of one kind it stays that kind; only tags take the other's.
    expect(
      resolve([
        { op: "update", documentId: "d-car", tags: ["A"] },
        { op: "update", documentId: "d-car", append: "One" },
        { op: "update", documentId: "d-car", append: "Two", tags: ["B"] },
      ]),
    ).toEqual([
      expect.objectContaining({ change: "append", content: `${CAR.trimEnd()}\n\nOne\n\nTwo\n`, added: "One\n\nTwo", tags: ["B"] }),
    ]);
    // A later op that undoes nothing new is refused.
    expect(
      err([
        { op: "update", documentId: "d-car", append: "One" },
        { op: "update", documentId: "d-car", replace: [{ find: "5W-30", with: "5W-30" }] },
      ]),
    ).toMatch(/^400 ops\[1\]: update changes nothing/);
  });

  it("sums an edit up for the card", () => {
    const sum = (ops: unknown[], lang: "en" | "de" = "en") => notesEditSummary(resolve(ops), lang);
    expect(sum([{ op: "create", path: "Notes/Car wash", content: "x" }])).toBe("Create “Car wash.md”");
    expect(sum([{ op: "create", path: "Notes/Car wash", content: "x" }], "de")).toBe("„Car wash.md“ anlegen");
    expect(sum([{ op: "update", documentId: "d-car", append: "x" }])).toBe("Change “Car.md”");
    const mixed = [
      { op: "create", path: "a", content: "x" },
      { op: "create", path: "b", content: "x" },
      { op: "update", documentId: "d-car", append: "x" },
    ];
    expect(sum(mixed)).toBe("Create 2 notes, change 1 note");
    expect(sum(mixed, "de")).toBe("2 Notizen anlegen, 1 Notiz ändern");
  });
});

// A note in the family's folder with its text (what an upload makes).
function addNote(db: Db, familyId: string, path: string, text: string, extra: Partial<typeof kbDocuments.$inferInsert> = {}) {
  const folderId = ensureFolder(db, familyId, null, NOW).folder.id;
  const id = randomUUID();
  const hash = createHash("sha256").update(text).digest("hex");
  db.insert(kbDocuments)
    .values({
      id,
      familyId,
      folderId,
      path,
      name: path.split("/").at(-1)!,
      hash,
      size: Buffer.byteLength(text),
      pages: 1,
      text: JSON.stringify([text]),
      mtime: 1_700_000_000_000,
      status: "ready",
      indexedAt: NOW,
      cardStatus: "none",
      createdAt: NOW,
      updatedAt: NOW,
      ...extra,
    })
    .run();
  return { id, hash, folderId };
}

function toolCtx(t: AssistantTest, knowledgeFolder?: string): ToolContext {
  return {
    lang: "en",
    calendar: new DrizzleCalendarStore(t.db),
    finance: new DrizzleFinanceStore(t.db),
    db: t.db,
    familyId: t.familyId,
    net: {} as NetOptions,
    search: null,
    userId: t.editor.id,
    today: CONTEXT.today,
    now: () => NOW,
    knowledge: true,
    knowledgeFolder,
  };
}

const tool = async (ctx: ToolContext, args: unknown): Promise<Res> =>
  (await runTool("edit_knowledge_notes", JSON.stringify(args), ctx, new Set(Object.keys(TOOLS)))) as Res;

describe("edit_knowledge_notes: who gets it", () => {
  it("toolsFor offers it only with the knowledge tools, the folder linked and changes on", () => {
    const names = (opts: Parameters<typeof toolsFor>[0]) => toolsFor(opts).map((x) => x.function.name);
    expect(names({ writes: true, search: false, knowledge: true })).not.toContain("edit_knowledge_notes");
    expect(names({ writes: true, search: false, knowledge: true, knowledgeNotes: true })).toContain("edit_knowledge_notes");
    expect(names({ writes: false, search: false, knowledge: true, knowledgeNotes: true })).not.toContain("edit_knowledge_notes");
    expect(names({ writes: true, search: false, knowledgeNotes: true })).not.toContain("edit_knowledge_notes");
    process.env.DISABLED_MODULES = "knowledge";
    expect(names({ writes: true, search: false, knowledge: true, knowledgeNotes: true })).not.toContain("edit_knowledge_notes");
  });

  it("the context keeps the folder's id the app sent", () => {
    expect(cleanContext({ ...CONTEXT })).not.toHaveProperty("knowledgeFolder");
    expect(cleanContext({ ...CONTEXT, knowledgeFolder: "f-1" }).knowledgeFolder).toBe("f-1");
    expect(cleanContext({ ...CONTEXT, knowledgeFolder: "" })).not.toHaveProperty("knowledgeFolder");
    expect(cleanContext({ ...CONTEXT, knowledgeFolder: 7 })).not.toHaveProperty("knowledgeFolder");
    expect(cleanContext({ ...CONTEXT, knowledgeFolder: "x".repeat(101) })).not.toHaveProperty("knowledgeFolder");
  });

  it("a chat gets it only for the family's folder, editors and changes on", async () => {
    const t = assistantTest();
    current.push(t);
    await configure(t);
    const { folderId } = addNote(t.db, t.familyId, "Notes/Car.md", CAR);
    const toolNames = () => (net.aiBody?.tools ?? []).map((x: { function: { name: string } }) => x.function.name);
    const system = () => String(net.aiBody.messages[0].content);
    const chat = async (extra: Record<string, unknown>, as = t.call) => {
      const res = await as("POST", `${t.ai}/chats`, { text: "hello", ...CONTEXT, ...extra });
      expect(res.status, JSON.stringify(res.data)).toBe(200);
      await idle(t, res.data[0].data.id, as);
    };

    await chat({ knowledgeFolder: folderId });
    expect(toolNames()).toContain("edit_knowledge_notes");
    expect(system()).toContain("edit_knowledge_notes creates one");
    expect(system()).toContain("edit_apple_calendar,\nedit_knowledge_notes or suggest_items");

    await chat({});
    expect(toolNames()).toContain("search_knowledge");
    expect(toolNames()).not.toContain("edit_knowledge_notes");
    expect(system()).toContain("Notes can't be written from this chat");

    await chat({ knowledgeFolder: "another-folder" });
    expect(toolNames()).not.toContain("edit_knowledge_notes");

    await chat({ knowledgeFolder: folderId }, t.view);
    expect(toolNames()).not.toContain("edit_knowledge_notes");
    expect(system()).not.toContain("Notes can't be written");

    await configure(t, { allowWrites: false });
    await chat({ knowledgeFolder: folderId });
    expect(toolNames()).toContain("search_knowledge");
    expect(toolNames()).not.toContain("edit_knowledge_notes");
    expect(system()).toContain("Notes can't be written from this chat");
  });

  it("refuses to run without the folder, or when the family's folder changed", async () => {
    const t = assistantTest({ worker: false });
    current.push(t);
    const { folderId } = addNote(t.db, t.familyId, "Notes/Car.md", CAR);
    const op = { ops: [{ op: "create", path: "Notes/Bike.md", content: "# Bike" }] };
    expect((await tool(toolCtx(t), op)).result).toEqual({ error: "Notes can't be written from this chat" });
    expect((await tool({ ...toolCtx(t, folderId), knowledge: false }, op)).result.error).toMatch(/knowledge base isn't available/);
    const ok = await tool(toolCtx(t, folderId), op);
    expect(ok).toMatchObject({
      ok: true,
      result: { waiting: true },
      summary: "Create “Bike.md”",
      notes: { summary: "Create “Bike.md”", ops: [{ op: "create", path: "Notes/Bike.md", title: "Bike.md", content: "# Bike" }] },
    });
    replaceFolder(t.db, t.familyId, null, NOW);
    expect((await tool(toolCtx(t, folderId), op)).result).toEqual({ error: "The knowledge folder changed" });
  });

  it("finds the documents of the family's folder only", async () => {
    const t = assistantTest({ worker: false });
    current.push(t);
    const car = addNote(t.db, t.familyId, "Notes/Car.md", CAR);
    const index = noteIndex(t.db, t.familyId, car.folderId);
    expect(index.byId(car.id)).toEqual({
      id: car.id,
      path: "Notes/Car.md",
      name: "Car.md",
      hash: car.hash,
      size: CAR.length,
      status: "ready",
      pages: [CAR],
    });
    expect(index.byPath("Notes/Car.md")?.id).toBe(car.id);
    expect(index.byPath("Notes/car.md")).toBeNull();
    expect(noteIndex(t.db, t.familyId, "other").byId(car.id)).toBeNull();
    expect(noteIndex(t.db, "other-family", car.folderId).byPath("Notes/Car.md")).toBeNull();
  });
});

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function idle(t: AssistantTest, id: string, as = t.call): Promise<any[]> {
  for (let i = 0; i < 500; i++) {
    const res = await as("GET", `${t.ai}/chats/${id}`);
    if (res.data.chat.status === "idle") return res.data.items;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error("The chat kept running");
}

describe("a notes edit in a chat", () => {
  async function setup() {
    const t = assistantTest();
    current.push(t);
    await configure(t);
    const car = addNote(t.db, t.familyId, "Notes/Car.md", CAR);
    return { t, car, context: { ...CONTEXT, knowledgeFolder: car.folderId } };
  }
  const toolMessage = (t: AssistantTest, id: string, callId: string) =>
    t.store
      .listChatMessages(id)
      .then((rows) => rows.map((r) => r.message).find((m) => m.role === "tool" && m.tool_call_id === callId));

  it("waits for the user, and goes on once the app wrote the notes", async () => {
    const { t, context } = await setup();
    const res = await t.call("POST", `${t.ai}/chats`, { text: "note Notes/Bike: # Bike\n\nTyres: 2.5 bar", ...context });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    const id = res.data[0].data.id as string;
    let list = await idle(t, id);
    const edit = list.at(-1);
    expect(edit).toEqual({
      kind: "notes",
      id: expect.any(String),
      summary: "Create “Bike.md”",
      ops: [{ op: "create", path: "Notes/Bike.md", title: "Bike.md", content: "# Bike\n\nTyres: 2.5 bar" }],
    });
    expect(list.some((it) => it.kind === "tool")).toBe(false);
    // Only as the notes edit, and with the results.
    expect((await t.call("POST", `${t.ai}/chats/${id}/reminders`, { id: edit.id, applied: false, ...context })).status).toBe(409);
    expect((await t.call("POST", `${t.ai}/chats/${id}/notes`, { id: "nope", applied: false, ...context })).status).toBe(409);
    expect((await t.call("POST", `${t.ai}/chats/${id}/notes`, { id: edit.id, applied: true, ...context })).status).toBe(400);

    const done = await t.call("POST", `${t.ai}/chats/${id}/notes`, {
      id: edit.id,
      applied: true,
      results: [{ ok: true, id: "Notes/Bike.md" }],
      ...context,
    });
    expect(done.status, JSON.stringify(done.data)).toBe(200);
    list = await idle(t, id);
    expect(list.find((it) => it.kind === "notes").answer).toEqual({ applied: true, results: [{ ok: true, id: "Notes/Bike.md" }] });
    expect(list.at(-1)).toEqual({ kind: "assistant", text: "Done: 1 of 1 note changes applied." });
    expect(JSON.parse(String((await toolMessage(t, id, edit.id))?.content))).toEqual({
      applied: true,
      results: [{ op: "create", title: "Bike.md", ok: true, id: "Notes/Bike.md" }],
    });
    expect(((await t.store.getChat(id))!.context as { knowledgeFolder?: string }).knowledgeFolder).toBe(context.knowledgeFolder);
    expect((await t.call("POST", `${t.ai}/chats/${id}/notes`, { id: edit.id, applied: false, ...context })).status).toBe(409);
  });

  it("tells the model when the user declined, and when the change doesn't fit", async () => {
    const { t, car, context } = await setup();
    const res = await t.call("POST", `${t.ai}/chats`, { text: `append to ${car.id}: Inspection: May 2027`, ...context });
    const id = res.data[0].data.id as string;
    const edit = (await idle(t, id)).at(-1);
    expect(edit).toMatchObject({
      kind: "notes",
      summary: "Change “Car.md”",
      ops: [
        {
          op: "update",
          documentId: car.id,
          path: "Notes/Car.md",
          baseHash: car.hash,
          change: "append",
          added: "Inspection: May 2027",
          content: `${CAR.trimEnd()}\n\nInspection: May 2027\n`,
        },
      ],
    });
    await t.call("POST", `${t.ai}/chats/${id}/notes`, { id: edit.id, applied: false, ...context });
    let list = await idle(t, id);
    expect(list.find((it) => it.id === edit.id).answer).toEqual({ applied: false });
    expect(list.at(-1).text).toBe("OK, I left your notes as they were.");
    expect(JSON.parse(String((await toolMessage(t, id, edit.id))?.content))).toEqual({
      applied: false,
      note: "The user declined these changes: nothing was changed in their knowledge folder.",
    });

    // A note that isn't there: the model hears why, nothing waits.
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "append to Notes/Boat.md: x", ...context });
    list = await idle(t, id);
    expect(list.filter((it) => it.kind === "notes")).toHaveLength(1);
    expect(list.at(-1).text).toMatch(/^That didn't work: ops\[0\]: No note "Notes\/Boat.md" in the knowledge folder/);

    // A new message skips a waiting edit.
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "note Ideas: - more", ...context });
    const skipped = (await idle(t, id)).at(-1);
    expect(skipped).toMatchObject({ kind: "notes", summary: "Create “Ideas.md”" });
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "never mind", ...context });
    expect((await idle(t, id)).find((it) => it.id === skipped.id).skipped).toBe(true);
    expect(JSON.parse(String((await toolMessage(t, id, skipped.id))?.content))).toMatchObject({
      skipped: true,
      note: expect.stringMatching(/nothing was changed in their knowledge folder/),
    });
  });
});
