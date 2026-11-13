// view_knowledge_pages (lib/assistant/tools/knowledge-pages.ts): the assistant looks at a
// document's pages as pictures. The files are on the user's device, so it waits like the notes
// tool: the app uploads each page (PUT …/pages?call=&page=), then answers (POST …/pages), and the
// pages reach the model as images in a message of their own, kept as files (page-images.ts). And
// how many chats each member keeps (retention.ts).

import { mkdtempSync, rmSync, existsSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { NetOptions } from "@/lib/assistant/net";
import { estimateTokens, newestImages, viewOf } from "@/lib/assistant/context";
import { deleteChatFiles, isPagesMessage, pageFilePath, pruneChatFiles, withPageImages, writePageFile } from "@/lib/assistant/page-images";
import { chatLimitOf, trimChats } from "@/lib/assistant/retention";
import { runTool, type ToolContext, TOOLS, toolsFor } from "@/lib/assistant/tools";
import { pagesFor, pagesSummary, resolvePages } from "@/lib/assistant/tools/knowledge-pages";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import type { Db } from "@/lib/db";
import { chats, kbDocuments, kbFolders } from "@/lib/db/schema";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { ensureFolder, replaceFolder } from "@/lib/knowledge/folders";
import { type AssistantTest, assistantTest, BASE, configure, net } from "@/lib/test/assistant";
import { NOW } from "@/lib/test/factories";
import { eq } from "drizzle-orm";

let current: AssistantTest[] = [];
let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "ohana-pages-"));
  process.env.MEDIA_ROOT = dir;
});
afterEach(async () => {
  await Promise.all(current.map((t) => t.stop()));
  current = [];
  delete process.env.DISABLED_MODULES;
  delete process.env.MEDIA_ROOT;
  rmSync(dir, { recursive: true, force: true });
});

const CONTEXT = { today: "2026-11-02", year: 2026, lang: "en", page: "overview" };
/** The smallest thing the routes take for a JPEG: SOI and a marker. */
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Res = { ok: boolean; result: any; summary: string; pages?: any };

function addDocument(db: Db, familyId: string, path: string, pages: number, extra: Partial<typeof kbDocuments.$inferInsert> = {}) {
  const { folder } = ensureFolder(db, familyId, null, NOW);
  const id = randomUUID();
  db.insert(kbDocuments)
    .values({
      id,
      familyId,
      folderId: folder.id,
      path,
      name: path.split("/").at(-1)!,
      hash: `hash-${id}`,
      size: 1000,
      pages,
      text: JSON.stringify(Array.from({ length: pages }, (_, i) => `Page ${i + 1}`)),
      mtime: 1_700_000_000_000,
      status: "ready",
      indexedAt: NOW,
      cardStatus: "none",
      createdAt: NOW,
      updatedAt: NOW,
      ...extra,
    })
    .run();
  return { id, folderId: folder.id };
}

function toolCtx(t: AssistantTest, knowledgeFolder?: string, contextWindow?: number): ToolContext {
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
    contextWindow,
  };
}

const tool = async (ctx: ToolContext, args: unknown): Promise<Res> =>
  (await runTool("view_knowledge_pages", JSON.stringify(args), ctx, new Set(Object.keys(TOOLS)))) as Res;

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function idle(t: AssistantTest, id: string): Promise<any[]> {
  for (let i = 0; i < 500; i++) {
    const res = await t.call("GET", `${t.ai}/chats/${id}`);
    if (res.data.chat.status === "idle") return res.data.items;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error("The chat kept running");
}

/** PUT …/pages as the app does: the JPEG as the body. */
async function putPage(t: AssistantTest, id: string, call: string, page: number, body: Buffer = JPEG, type = "image/jpeg") {
  const res = await t.handler(
    new Request(`${BASE}${t.ai}/chats/${id}/pages?call=${encodeURIComponent(call)}&page=${page}`, {
      method: "PUT",
      headers: { authorization: `Bearer ${t.editor.token}`, "content-type": type },
      body: new Uint8Array(body),
    }),
  );
  return res.status;
}

describe("view_knowledge_pages: the pages asked for", () => {
  it("takes page numbers and ranges, all pages without, within the limit", () => {
    expect(resolvePages(undefined, 4, 30)).toEqual([1, 2, 3, 4]);
    expect(resolvePages([], 40, 30)).toHaveLength(30);
    expect(resolvePages(undefined, 0, 5)).toEqual([1, 2, 3, 4, 5]);
    expect(resolvePages(["3-5", 1, "4", " 7 "], 10, 30)).toEqual([1, 3, 4, 5, 7]);
    expect(resolvePages("2–3", 10, 30)).toEqual([2, 3]);
    expect(() => resolvePages([11], 10, 30)).toThrow("The document has 10 pages");
    expect(() => resolvePages(["0"], 10, 30)).toThrow(/page numbers/);
    expect(() => resolvePages(["5-3"], 10, 30)).toThrow(/page numbers/);
    expect(() => resolvePages(["x"], 10, 30)).toThrow(/page numbers/);
    expect(() => resolvePages(["1-6"], 10, 5)).toThrow("At most 5 pages at a time: ask for the rest in another call");
  });

  it("fits the pages to the model's context window", () => {
    expect(pagesFor(undefined)).toBe(25);
    expect(pagesFor(1_000_000)).toBe(30);
    expect(pagesFor(32_000)).toBe(6);
    expect(pagesFor(2_000)).toBe(1);
  });

  it("sums the request up for the card", () => {
    expect(pagesSummary("Befund.pdf", [1, 2, 3, 7], 9, "en")).toBe("Look at pages 1–3, 7 of “Befund.pdf”");
    expect(pagesSummary("Befund.pdf", [2], 9, "en")).toBe("Look at page 2 of “Befund.pdf”");
    expect(pagesSummary("Befund.pdf", [1, 2], 2, "en")).toBe("Look at all 2 pages of “Befund.pdf”");
    expect(pagesSummary("Foto.jpg", [1], 1, "de")).toBe("„Foto.jpg“ ansehen");
    expect(pagesSummary("Befund.pdf", [4, 5], 9, "de")).toBe("Seiten 4–5 von „Befund.pdf“ ansehen");
  });
});

describe("view_knowledge_pages: who gets it", () => {
  it("toolsFor offers it with the folder linked, also with changes off", () => {
    const names = (opts: Parameters<typeof toolsFor>[0]) => toolsFor(opts).map((x) => x.function.name);
    expect(names({ writes: true, search: false, knowledge: true })).not.toContain("view_knowledge_pages");
    expect(names({ writes: false, search: false, knowledge: true, knowledgeNotes: true })).toContain("view_knowledge_pages");
    expect(names({ writes: true, search: false, knowledgeNotes: true })).not.toContain("view_knowledge_pages");
    process.env.DISABLED_MODULES = "knowledge";
    expect(names({ writes: true, search: false, knowledge: true, knowledgeNotes: true })).not.toContain("view_knowledge_pages");
  });

  it("checks the folder, the document and its pages", async () => {
    const t = assistantTest({ worker: false });
    current.push(t);
    const pdf = addDocument(t.db, t.familyId, "Health/Befund.pdf", 3);
    const photo = addDocument(t.db, t.familyId, "Photo.HEIC", 1);
    const notes = addDocument(t.db, t.familyId, "Notes/Car.md", 1);
    const gone = addDocument(t.db, t.familyId, "Old.pdf", 2, { status: "missing" });
    const out = addDocument(t.db, t.familyId, "Out.pdf", 2, { status: "excluded" });
    const ctx = toolCtx(t, pdf.folderId);

    expect((await tool(toolCtx(t), { documentId: pdf.id })).result.error).toBe("The documents' files aren't on this device");
    expect((await tool({ ...ctx, knowledge: false }, { documentId: pdf.id })).result.error).toMatch(/knowledge base isn't available/);
    expect((await tool(ctx, { documentId: "nope" })).result.error).toBe('No document "nope" in the knowledge base');
    expect((await tool(ctx, { documentId: out.id })).result.error).toMatch(/^No document/);
    expect((await tool(ctx, { documentId: gone.id })).result.error).toMatch(/isn't in the knowledge folder any more/);
    expect((await tool(ctx, { documentId: notes.id })).result.error).toMatch(/Only PDFs and images/);
    expect((await tool(ctx, { documentId: pdf.id, pages: ["4"] })).result.error).toBe("The document has 3 pages");

    const all = await tool(ctx, { documentId: pdf.id });
    expect(all).toMatchObject({
      ok: true,
      result: { waiting: true },
      summary: "Look at all 3 pages of “Befund.pdf”",
      pages: {
        documentId: pdf.id,
        name: "Befund.pdf",
        path: "Health/Befund.pdf",
        hash: `hash-${pdf.id}`,
        pages: [1, 2, 3],
        total: 3,
        auto: false,
      },
    });
    expect((await tool(ctx, { documentId: photo.id, pages: ["1"] })).pages).toMatchObject({ pages: [1], total: 1 });
    // The family's switch: the app sends without asking.
    t.db.update(kbFolders).set({ aiScans: true }).where(eq(kbFolders.id, pdf.folderId)).run();
    expect((await tool(ctx, { documentId: pdf.id, pages: ["2"] })).pages).toMatchObject({ pages: [2], auto: true });
    // A small context window: fewer pages at a time.
    expect((await tool(toolCtx(t, pdf.folderId, 8000), { documentId: pdf.id })).pages.pages).toEqual([1]);

    replaceFolder(t.db, t.familyId, null, NOW);
    expect((await tool(ctx, { documentId: pdf.id })).result.error).toBe("The knowledge folder changed");
  });
});

describe("the pages in a chat", () => {
  async function setup(pages = 3) {
    const t = assistantTest();
    current.push(t);
    await configure(t);
    const doc = addDocument(t.db, t.familyId, "Health/Befund.pdf", pages);
    return { t, doc, context: { ...CONTEXT, knowledgeFolder: doc.folderId } };
  }
  const messages = (t: AssistantTest, id: string) => t.store.listChatMessages(id).then((rows) => rows.map((r) => r.message));

  it("waits for the app, takes the pages it uploads and shows them to the model", async () => {
    const { t, doc, context } = await setup();
    const res = await t.call("POST", `${t.ai}/chats`, { text: `look at ${doc.id} pages 1-2`, ...context });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    const id = res.data[0].data.id as string;
    let items = await idle(t, id);
    const wait = items.at(-1);
    expect(wait).toEqual({
      kind: "pages",
      id: expect.any(String),
      summary: "Look at pages 1–2 of “Befund.pdf”",
      documentId: doc.id,
      name: "Befund.pdf",
      path: "Health/Befund.pdf",
      hash: `hash-${doc.id}`,
      pages: [1, 2],
      total: 3,
      auto: false,
    });
    expect(String(net.aiBody.messages[0].content)).toContain("view_knowledge_pages shows you pages");

    // Only the pages asked for, as JPEGs, for the call that waits.
    expect(await putPage(t, id, "other", 1)).toBe(409);
    expect(await putPage(t, id, wait.id, 3)).toBe(400);
    expect(await putPage(t, id, wait.id, 1, Buffer.from("not a jpeg"))).toBe(400);
    expect(await putPage(t, id, wait.id, 1, JPEG, "image/png")).toBe(415);
    expect(await putPage(t, id, wait.id, 1)).toBe(200);
    expect(await putPage(t, id, wait.id, 2)).toBe(200);
    expect(existsSync(join(dir, pageFilePath(t.familyId, id, wait.id, 2)))).toBe(true);
    expect((await t.call("POST", `${t.ai}/chats/${id}/pages`, { id: "nope", sent: [1], ...context })).status).toBe(409);

    // Only pages asked for and uploaded count (3 was neither).
    const done = await t.call("POST", `${t.ai}/chats/${id}/pages`, { id: wait.id, sent: [1, 2, 3], ...context });
    expect(done.status, JSON.stringify(done.data)).toBe(200);
    items = await idle(t, id);
    expect(items.find((it) => it.id === wait.id).answer).toEqual({ sent: [1, 2] });
    expect(items.at(-1)).toEqual({ kind: "assistant", text: "Saw 2 pages: [Pages for view_knowledge_pages: “Befund.pdf”, pages 1–2]" });

    // Kept as files: the messages refer to them, the model got data URLs.
    const stored = await messages(t, id);
    const result = stored.find((m) => m.role === "tool" && m.tool_call_id === wait.id);
    expect(JSON.parse(String(result?.content))).toEqual({
      document: "Befund.pdf",
      sent: "pages 1–2",
      note: "The pages follow as images in the next message.",
      left: "page 3 not sent yet: call again with them if you need them",
    });
    const pagesMessage = stored.find((m) => m.role === "user" && isPagesMessage(m as never));
    expect(JSON.stringify(pagesMessage)).toContain(`"url":"media:assistant/${t.familyId}/${id}/`);
    expect(JSON.stringify(pagesMessage)).not.toContain("data:image");
    const sentToModel = net.aiBody.messages.find((m: { role: string; content: unknown }) => m.role === "user" && Array.isArray(m.content) && JSON.stringify(m.content).includes("Pages for view_knowledge_pages"));
    const urls = sentToModel.content.filter((p: { type: string }) => p.type === "image_url").map((p: { image_url: { url: string } }) => p.image_url.url);
    expect(urls).toEqual([1, 2].map(() => `data:image/jpeg;base64,${JPEG.toString("base64")}`));

    // No longer asked for.
    expect(await putPage(t, id, wait.id, 1)).toBe(409);

    // The chat's files go with it.
    expect((await t.call("DELETE", `${t.ai}/chats/${id}`)).status).toBe(200);
    expect(existsSync(join(dir, "assistant", t.familyId, id))).toBe(false);
  });

  it("tells the model when the user declined, the device couldn't, or a new message came", async () => {
    const { t, doc, context } = await setup();
    const res = await t.call("POST", `${t.ai}/chats`, { text: `look at ${doc.id}`, ...context });
    const id = res.data[0].data.id as string;
    let wait = (await idle(t, id)).at(-1);
    expect(wait).toMatchObject({ kind: "pages", pages: [1, 2, 3], summary: "Look at all 3 pages of “Befund.pdf”" });
    await t.call("POST", `${t.ai}/chats/${id}/pages`, { id: wait.id, declined: true, ...context });
    let items = await idle(t, id);
    expect(items.find((it) => it.id === wait.id).answer).toEqual({ declined: true });
    expect(items.at(-1).text).toBe("No pages: declined");

    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: `look at ${doc.id} pages 2`, ...context });
    wait = (await idle(t, id)).at(-1);
    await t.call("POST", `${t.ai}/chats/${id}/pages`, { id: wait.id, sent: [2], error: "The file isn’t in the folder any more.", ...context });
    items = await idle(t, id);
    expect(items.find((it) => it.id === wait.id).answer).toEqual({ error: "The file isn’t in the folder any more." });
    expect(items.at(-1).text).toBe("No pages: The pages couldn't be sent: The file isn’t in the folder any more.");

    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: `look at ${doc.id} pages 3`, ...context });
    wait = (await idle(t, id)).at(-1);
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "never mind", ...context });
    items = await idle(t, id);
    expect(items.find((it) => it.id === wait.id).skipped).toBe(true);
    const skipped = (await messages(t, id)).find((m) => m.role === "tool" && m.tool_call_id === wait.id);
    expect(JSON.parse(String(skipped?.content))).toMatchObject({ skipped: true });
  });

  it("isn't offered without the folder linked on the device", async () => {
    const { t, doc } = await setup();
    const res = await t.call("POST", `${t.ai}/chats`, { text: `look at ${doc.id}`, ...CONTEXT });
    const id = res.data[0].data.id as string;
    await idle(t, id);
    const names = (net.aiBody?.tools ?? []).map((x: { function: { name: string } }) => x.function.name);
    expect(names).toContain("read_knowledge");
    expect(names).not.toContain("view_knowledge_pages");
    expect(String(net.aiBody.messages[0].content)).not.toContain("view_knowledge_pages");
  });
});

describe("the page images the model gets", () => {
  const text = (t: string) => ({ type: "text" as const, text: t });
  const image = (url: string) => ({ type: "image_url" as const, image_url: { url } });

  it("keeps every image of the newest message with images, older ones up to the limit", () => {
    const old = { role: "user" as const, content: [text("photos"), ...Array.from({ length: 4 }, (_, i) => image(`data:image/png;base64,A${i}`))] };
    const pages = { role: "user" as const, content: [text("[Pages for view_knowledge_pages: x]"), ...Array.from({ length: 12 }, (_, i) => image(`media:p${i}`))] };
    const out = newestImages([old, { role: "assistant", content: "ok" }, pages]);
    expect((out[2].content as unknown[]).filter((p) => (p as { type: string }).type === "image_url")).toHaveLength(12);
    expect((out[0].content as { type: string }[]).every((p) => p.type === "text")).toBe(true);
    expect(viewOf([old])).toEqual([old]);
    expect(estimateTokens([pages])).toBeGreaterThan(12_000);
  });

  it("reads the page files into data URLs for the request; a file that's gone is told", () => {
    const rel = writePageFile("fam1", "chat1", "call-1", 1, JPEG);
    const out = withPageImages([
      { role: "user", content: [text("[Pages for view_knowledge_pages: x]"), image(`media:${rel}`), image("media:assistant/fam1/chat1/gone.jpg"), image("media:../../etc/passwd")] },
      { role: "user", content: "plain" },
    ]);
    expect(out[0].content).toEqual([
      text("[Pages for view_knowledge_pages: x]"),
      image(`data:image/jpeg;base64,${JPEG.toString("base64")}`),
      text("(a page image that is no longer kept)"),
      text("(a page image that is no longer kept)"),
    ]);
    expect(out[1]).toEqual({ role: "user", content: "plain" });
    deleteChatFiles("fam1", "chat1");
    expect(existsSync(join(dir, rel))).toBe(false);
  });
});

describe("the chats each member keeps", () => {
  it("is a setting of the family's assistant, for editors: 50 unless set", async () => {
    const t = assistantTest({ worker: false });
    current.push(t);
    expect((await configure(t)).chatLimit).toBe(50);
    expect((await t.call("PUT", `${t.ai}/settings`, { chatLimit: 20 })).data.chatLimit).toBe(20);
    expect((await t.call("GET", `${t.ai}/settings`)).data.chatLimit).toBe(20);
    expect((await t.view("GET", `${t.ai}/settings`)).data.chatLimit).toBe(20);
    expect((await t.view("PUT", `${t.ai}/settings`, { chatLimit: 100 })).status).toBe(403);
    for (const bad of [0, 4, 1.5, "30", 1001]) {
      expect((await t.call("PUT", `${t.ai}/settings`, { chatLimit: bad })).status).toBe(400);
    }
  });

  it("keeps each member's newest chats, deleting the others with their page images, not running ones", async () => {
    const t = assistantTest({ worker: false });
    current.push(t);
    await configure(t);
    const minute = 60_000;
    const chat = (userId: string, age: number, status = "idle") => {
      const id = randomUUID();
      const at = new Date(NOW.getTime() - age * minute);
      t.db.insert(chats).values({ id, familyId: t.familyId, userId, status, createdAt: at, updatedAt: at }).run();
      writePageFile(t.familyId, id, "call", 1, JPEG);
      return id;
    };
    const mine = Array.from({ length: 8 }, (_, i) => chat(t.editor.id, i));
    const running = chat(t.editor.id, 100, "running");
    const theirs = Array.from({ length: 6 }, (_, i) => chat(t.viewer.id, i));
    const ids = (userId: string) =>
      t.db.select({ id: chats.id }).from(chats).where(eq(chats.userId, userId)).all().map((c) => c.id).sort();

    expect(trimChats(t.db, t.familyId, 5, t.editor.id)).toBe(3);
    expect(ids(t.editor.id)).toEqual([...mine.slice(0, 5), running].sort());
    expect(ids(t.viewer.id)).toHaveLength(6);
    expect(existsSync(join(dir, "assistant", t.familyId, mine[7]))).toBe(false);
    expect(existsSync(join(dir, "assistant", t.familyId, mine[0]))).toBe(true);

    // Lowering the limit trims every member at once.
    expect((await t.call("PUT", `${t.ai}/settings`, { chatLimit: 5 })).status).toBe(200);
    expect(ids(t.viewer.id)).toEqual(theirs.slice(0, 5).sort());
    expect(chatLimitOf(t.db, t.familyId)).toBe(5);

    // A new chat counts: the oldest goes.
    expect(await t.fire("POST", `${t.ai}/chats`, { text: "hello", ...CONTEXT })).toBe(200);
    expect(ids(t.editor.id)).toHaveLength(6);
    expect(ids(t.editor.id)).not.toContain(mine[4]);
    expect(ids(t.editor.id)).toContain(running);
  });

  it("sweeps the page folders of chats that are gone", () => {
    const t = assistantTest({ worker: false });
    current.push(t);
    const id = randomUUID();
    t.db.insert(chats).values({ id, familyId: t.familyId, userId: t.editor.id, createdAt: NOW, updatedAt: NOW }).run();
    writePageFile(t.familyId, id, "call", 1, JPEG);
    writePageFile(t.familyId, "gone-chat", "call", 1, JPEG);
    writePageFile("gone-family", "gone-chat-2", "call", 1, JPEG);
    expect(pruneChatFiles(t.db)).toBe(2);
    expect(readdirSync(join(dir, "assistant"))).toEqual([t.familyId]);
    expect(readdirSync(join(dir, "assistant", t.familyId))).toEqual([id]);
  });
});
