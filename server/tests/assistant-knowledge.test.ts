// The assistant and the knowledge base (lib/assistant/tools/knowledge.ts, lib/assistant/sources.ts):
// the tools only for editors with the module on, search_knowledge's refs, read_knowledge's pages
// and facts, one family's documents only, and the source check of the answers' [[k:<id>]] markers
// (only refs a knowledge tool returned in the chat, of chunks that are still the family's).

import { createHash, randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { afterEach, describe, expect, it } from "vitest";
import type { NetOptions } from "@/lib/assistant/net";
import { checkSources, citedIds, statementBefore } from "@/lib/assistant/sources";
import { runTool, type ToolContext, TOOLS, toolsFor } from "@/lib/assistant/tools";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import type { Db } from "@/lib/db";
import { kbChunks, kbDocuments } from "@/lib/db/schema";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { chunkPages } from "@/lib/knowledge/chunk";
import { ensureFolder } from "@/lib/knowledge/folders";
import { type CitedChunk, EXCERPT_MAX, excerptOf } from "@/lib/knowledge/sources";
import { type AssistantTest, assistantTest, configure, net } from "@/lib/test/assistant";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

let current: AssistantTest[] = [];
afterEach(async () => {
  await Promise.all(current.map((t) => t.stop()));
  current = [];
  delete process.env.DISABLED_MODULES;
});

const CONTEXT = { today: "2026-11-02", year: 2026, lang: "en", page: "overview" };
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Res = { ok: boolean; result: any; summary: string; change?: unknown };

const sha = (s: string) => createHash("sha256").update(s).digest("hex");

/** A ready document with its pages chunked (what the worker makes); its chunk ids in order. */
function addDocument(
  db: Db,
  familyId: string,
  path: string,
  pages: string[],
  extra: Partial<typeof kbDocuments.$inferInsert> = {},
): { id: string; chunks: number[] } {
  const folderId = ensureFolder(db, familyId, null, NOW).folder.id;
  const id = randomUUID();
  db.insert(kbDocuments)
    .values({
      id,
      familyId,
      folderId,
      path,
      name: path.split("/").at(-1)!,
      hash: sha(path + pages.join()),
      pages: pages.length,
      text: JSON.stringify(pages),
      tags: JSON.stringify(["Versicherung"]),
      mtime: 1_700_000_000_000,
      status: "ready",
      indexedAt: NOW,
      cardStatus: "none",
      createdAt: NOW,
      updatedAt: NOW,
      ...extra,
    })
    .run();
  const chunks = chunkPages(pages).map(
    (c) =>
      db.insert(kbChunks).values({ documentId: id, familyId, seq: c.seq, page: c.page, text: c.text }).returning({ id: kbChunks.id }).get().id,
  );
  return { id, chunks };
}

const POLICY = [
  "Hausratversicherung, Police HR-2026-114. Die Selbstbeteiligung beträgt 150 Euro je Schadensfall.",
  "Kündigung: drei Monate zum Ende des Versicherungsjahres, schriftlich an die Versicherung.",
];

function setup() {
  const t = assistantTest();
  current.push(t);
  const policy = addDocument(t.db, t.familyId, "Versicherungen/Hausrat/Police.pdf", POLICY);
  return { t, policy };
}

async function chatWith(t: AssistantTest, text: string, as = t.call) {
  const res = await as("POST", `${t.ai}/chats`, { text, ...CONTEXT });
  expect(res.status, JSON.stringify(res.data)).toBe(200);
  const id = res.data[0].data.id as string;
  await idle(t, id, as);
  return id;
}

async function say(t: AssistantTest, id: string, text: string) {
  const res = await t.call("POST", `${t.ai}/chats/${id}/messages`, { text, ...CONTEXT });
  expect(res.status, JSON.stringify(res.data)).toBe(200);
  return idle(t, id);
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function idle(t: AssistantTest, id: string, as = t.call): Promise<any[]> {
  for (let i = 0; i < 500; i++) {
    const res = await as("GET", `${t.ai}/chats/${id}`);
    if (res.data.chat.status === "idle") return res.data.items;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error("The chat kept running");
}

const toolNames = () => (net.aiBody?.tools ?? []).map((x: { function: { name: string } }) => x.function.name);
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const lastAnswer = (items: any[]): { text: string; sources?: unknown[] } => items.findLast((it) => it.kind === "assistant");

function toolCtx(t: AssistantTest, familyId = t.familyId): ToolContext {
  return {
    lang: "en",
    calendar: new DrizzleCalendarStore(t.db),
    finance: new DrizzleFinanceStore(t.db),
    db: t.db,
    familyId,
    net: {} as NetOptions,
    search: null,
    userId: t.editor.id,
    today: CONTEXT.today,
    now: () => NOW,
    knowledge: true,
  };
}

const tool = async (ctx: ToolContext, name: string, args: unknown): Promise<Res> =>
  (await runTool(name, JSON.stringify(args), ctx, new Set(Object.keys(TOOLS)))) as Res;

describe("knowledge tools: who gets them", () => {
  it("only editors, with the module on and a folder; read-only, so with changes off too", async () => {
    const t = assistantTest();
    current.push(t);
    await configure(t, { allowWrites: false });
    await chatWith(t, "hello");
    expect(toolNames()).not.toContain("search_knowledge"); // no folder yet
    expect(net.aiBody.messages[0].content).not.toContain("## Knowledge base");

    addDocument(t.db, t.familyId, "a.pdf", ["Some text of a document"]);
    await chatWith(t, "hello");
    expect(toolNames()).toEqual(expect.arrayContaining(["search_knowledge", "read_knowledge"]));
    expect(net.aiBody.messages[0].content).toContain("## Knowledge base");
    expect(net.aiBody.messages[0].content).toContain("[[k:<id>]]");

    await chatWith(t, "hello", t.view);
    expect(toolNames()).not.toContain("search_knowledge");
    expect(toolNames()).not.toContain("read_knowledge");
    expect(net.aiBody.messages[0].content).not.toContain("## Knowledge base");

    process.env.DISABLED_MODULES = "knowledge";
    await chatWith(t, "hello");
    expect(toolNames()).not.toContain("search_knowledge");
  });

  it("toolsFor leaves them out without the flag or with the module off; runTool refuses them then", async () => {
    const t = assistantTest({ worker: false });
    current.push(t);
    const names = (k: boolean) => toolsFor({ writes: true, search: false, knowledge: k }).map((x) => x.function.name);
    expect(names(false)).not.toContain("search_knowledge");
    expect(names(true)).toEqual(expect.arrayContaining(["search_knowledge", "read_knowledge"]));
    expect(TOOLS.search_knowledge.write).toBeFalsy();
    expect(TOOLS.read_knowledge.write).toBeFalsy();
    process.env.DISABLED_MODULES = "knowledge";
    expect(names(true)).not.toContain("search_knowledge");
    const res = await tool({ ...toolCtx(t), knowledge: false }, "search_knowledge", { query: "x" });
    expect(res.ok).toBe(false);
  });
});

describe("knowledge tools", () => {
  it("search_knowledge returns passages with their refs", async () => {
    const { t, policy } = setup();
    const res = await tool(toolCtx(t), "search_knowledge", { query: "selbstbeteiligung" });
    expect(res.ok, JSON.stringify(res.result)).toBe(true);
    expect(res.result.hits).toEqual([
      {
        ref: `k:${policy.chunks[0]}`,
        documentId: policy.id,
        name: "Police.pdf",
        path: "Versicherungen/Hausrat/Police.pdf",
        page: 1,
        date: "2023-11-14",
        text: POLICY[0],
      },
    ]);
    // Filters and limits.
    expect((await tool(toolCtx(t), "search_knowledge", { query: "die", tags: ["Steuer"] })).result.hits).toEqual([]);
    expect((await tool(toolCtx(t), "search_knowledge", { query: "die", tags: ["Versicherung"] })).result.hits).toHaveLength(2);
    expect((await tool(toolCtx(t), "search_knowledge", { query: "die", folder: "Versicherungen/" })).result.hits).toHaveLength(2);
    expect((await tool(toolCtx(t), "search_knowledge", { query: "die", folder: "Steuern" })).result.hits).toEqual([]);
    expect((await tool(toolCtx(t), "search_knowledge", { query: "die", limit: 1 })).result.hits).toHaveLength(1);
    expect((await tool(toolCtx(t), "search_knowledge", { query: "die", limit: 21 })).ok).toBe(false);
    const none = await tool(toolCtx(t), "search_knowledge", { query: "zebra" });
    expect(none.result).toMatchObject({ hits: [], note: expect.stringMatching(/Nothing found/) });
  });

  it("search_knowledge gives a document's summary and date once, with its first passage", async () => {
    const { t, policy } = setup();
    t.db.update(kbDocuments).set({ summary: "Die Hausratpolice der Familie.", docDate: "2026-03-03" }).where(eq(kbDocuments.id, policy.id)).run();
    const res = await tool(toolCtx(t), "search_knowledge", { query: "die" });
    expect(res.result.hits.map((h: { summary?: string; date?: string }) => [h.summary, h.date])).toEqual([
      ["Die Hausratpolice der Familie.", "2026-03-03"],
      [undefined, "2026-03-03"],
    ]);
    // The summary finds the document too: "Familie" is only there.
    const bySummary = await tool(toolCtx(t), "search_knowledge", { query: "familie" });
    expect(bySummary.result.hits).toMatchObject([{ documentId: policy.id, summary: "Die Hausratpolice der Familie.", text: POLICY[0] }]);
  });

  it("read_knowledge: a short document whole, with the card's facts as refs", async () => {
    const { t, policy } = setup();
    const facts = [{ text: "Deductible 150 €", quote: "Die Selbstbeteiligung beträgt 150 Euro", chunkId: policy.chunks[0], page: 1 }];
    t.db.update(kbDocuments).set({ summary: "Die Hausratpolice.", docDate: "2026-03-03", facts: JSON.stringify(facts) }).where(eq(kbDocuments.id, policy.id)).run();
    const res = await tool(toolCtx(t), "read_knowledge", { documentId: policy.id });
    expect(res.ok, JSON.stringify(res.result)).toBe(true);
    expect(res.result).toEqual({
      document: {
        id: policy.id,
        name: "Police.pdf",
        path: "Versicherungen/Hausrat/Police.pdf",
        tags: ["Versicherung"],
        docDate: "2026-03-03",
        summary: "Die Hausratpolice.",
        facts: [{ text: "Deductible 150 €", quote: "Die Selbstbeteiligung beträgt 150 Euro", ref: `k:${policy.chunks[0]}`, page: 1 }],
      },
      pages: 2,
      page: null,
      chunks: [
        { ref: `k:${policy.chunks[0]}`, page: 1, text: POLICY[0] },
        { ref: `k:${policy.chunks[1]}`, page: 2, text: POLICY[1] },
      ],
    });
    const page2 = await tool(toolCtx(t), "read_knowledge", { documentId: policy.id, page: 2 });
    expect(page2.result).toMatchObject({ page: 2, pages: 2, chunks: [{ ref: `k:${policy.chunks[1]}` }], next: null });
    expect((await tool(toolCtx(t), "read_knowledge", { documentId: policy.id, page: 3 })).result.error).toMatch(/page must be 1–2/);
  });

  it("read_knowledge: a long document a page at a time, a very long page in parts", async () => {
    const { t } = setup();
    const para = (n: number) => `Absatz ${n}. ` + "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ".repeat(15);
    const pages = [
      Array.from({ length: 6 }, (_, i) => para(i)).join("\n\n"),
      "",
      Array.from({ length: 30 }, (_, i) => para(100 + i)).join("\n\n"),
    ];
    const doc = addDocument(t.db, t.familyId, "Handbuch.pdf", pages);
    const first = await tool(toolCtx(t), "read_knowledge", { documentId: doc.id });
    expect(first.ok, JSON.stringify(first.result)).toBe(true);
    expect(first.result).toMatchObject({ page: 1, pages: 3, next: { page: 3 } });
    expect(first.result.chunks.every((c: { page: number }) => c.page === 1)).toBe(true);
    expect(JSON.stringify(first.result).length).toBeLessThan(16_000);
    const empty = await tool(toolCtx(t), "read_knowledge", { documentId: doc.id, page: 2 });
    expect(empty.result).toMatchObject({ page: 2, chunks: [], next: { page: 3 } });
    const third = await tool(toolCtx(t), "read_knowledge", { documentId: doc.id, page: 3 });
    expect(third.result).toMatchObject({ page: 3, part: 1, parts: expect.any(Number), next: { page: 3, part: 2 } });
    expect(third.result.parts).toBeGreaterThan(1);
    const last = await tool(toolCtx(t), "read_knowledge", { documentId: doc.id, page: 3, part: third.result.parts });
    expect(last.result).toMatchObject({ part: third.result.parts, next: null });
    const all = [third, last].flatMap((r) => r.result.chunks.map((c: { text: string }) => c.text));
    expect(all.at(-1)).toContain("Absatz 129.");
    expect(JSON.stringify(third.result).length).toBeLessThan(16_000);
  });

  it("only the family's documents: another family's id or an excluded one is not found", async () => {
    const { t } = setup();
    const other = makeFamily(t.db, makeUser(t.db, { email: "other@test" }).id).id;
    const theirs = addDocument(t.db, other, "Geheim.pdf", ["Die Selbstbeteiligung des Nachbarn"]);
    const res = await tool(toolCtx(t), "read_knowledge", { documentId: theirs.id });
    expect(res.ok).toBe(false);
    expect(res.result.error).toMatch(/No document/);
    const hits = (await tool(toolCtx(t), "search_knowledge", { query: "selbstbeteiligung" })).result.hits;
    expect(hits.map((h: { documentId: string }) => h.documentId)).not.toContain(theirs.id);
    const excluded = addDocument(t.db, t.familyId, "Raus.pdf", ["Text"], { status: "excluded" });
    expect((await tool(toolCtx(t), "read_knowledge", { documentId: excluded.id })).ok).toBe(false);
  });
});

describe("the source check", () => {
  it("keeps a returned ref with its source, removes an invented one", async () => {
    const { t, policy } = setup();
    await configure(t);
    const id = await chatWith(t, "knowledge invent selbstbeteiligung");
    const items = await idle(t, id);
    const tool = items.find((it) => it.kind === "tool");
    expect(tool).toMatchObject({ name: "search_knowledge", status: "ok", summary: "1 hit" });
    const answer = lastAnswer(items);
    const ref = `k:${policy.chunks[0]}`;
    expect(answer.text).toBe(`Police.pdf says: ${POLICY[0].slice(0, 40)} [[${ref}]]. And this too.`);
    expect(answer.sources).toEqual([
      {
        ref,
        chunkId: policy.chunks[0],
        documentId: policy.id,
        name: "Police.pdf",
        path: "Versicherungen/Hausrat/Police.pdf",
        page: 1,
        quote: POLICY[0],
        excerpt: "Hausratversicherung, Police HR-2026-114.",
      },
    ]);
    // Recorded as the tool ran.
    expect((await t.store.getChat(id))?.knowledge_refs).toEqual([policy.chunks[0]]);
    // The model's history keeps what it wrote.
    const messages = (await t.store.listChatMessages(id)).map((r) => r.message);
    expect(messages.at(-1)?.content).toContain("[[k:999999]]");
  });

  it("keeps a ref of an earlier turn; removes one never returned, another family's and a deleted chunk", async () => {
    const { t, policy } = setup();
    await configure(t);
    const other = makeFamily(t.db, makeUser(t.db, { email: "other@test" }).id).id;
    const theirs = addDocument(t.db, other, "Geheim.pdf", ["Fremder Text"]);
    const id = await chatWith(t, "knowledge kündigung");
    const [first, second] = policy.chunks;
    expect(lastAnswer(await idle(t, id)).sources).toMatchObject([{ ref: `k:${second}`, page: 2 }]);

    // An earlier turn's result counts; a chunk of the family no tool returned doesn't, nor
    // another family's.
    let items = await say(t, id, `cite k:${second}, k:${first}, k:${theirs.chunks[0]}`);
    expect(lastAnswer(items)).toEqual({
      kind: "assistant",
      text: `Said here [[k:${second}]]. Said here. Said here.`,
      sources: [expect.objectContaining({ ref: `k:${second}`, chunkId: second, documentId: policy.id })],
    });

    // Once the chunk is gone (new text, the document deleted), its marker goes too.
    t.db.delete(kbChunks).where(eq(kbChunks.id, second)).run();
    items = await say(t, id, `cite k:${second}`);
    expect(lastAnswer(items)).toEqual({ kind: "assistant", text: "Said here." });
  });

  it("a viewer's answers keep no markers", async () => {
    const { t, policy } = setup();
    await configure(t);
    const id = await chatWith(t, `cite k:${policy.chunks[0]}`, t.view);
    expect(lastAnswer(await idle(t, id, t.view))).toEqual({ kind: "assistant", text: "Said here." });
  });

  it("an imported chat's history returns no refs, and its items lose their markers", async () => {
    const { t, policy } = setup();
    await configure(t);
    const ref = `k:${policy.chunks[0]}`;
    const res = await t.call("POST", `${t.ai}/chats/import`, {
      title: "Old",
      items: [{ kind: "user", text: "deductible?" }, { kind: "assistant", text: `150 € [[${ref}]].` }],
      history: [
        { role: "user", content: "deductible?" },
        { role: "assistant", content: null, tool_calls: [{ id: "c1", type: "function", function: { name: "search_knowledge", arguments: "{}" } }] },
        { role: "tool", tool_call_id: "c1", content: JSON.stringify({ hits: [{ ref, text: POLICY[0] }] }) },
        { role: "assistant", content: `150 € [[${ref}]].` },
      ],
    });
    expect(res.status, JSON.stringify(res.data)).toBe(201);
    const id = res.data.chat.id as string;
    expect(lastAnswer(await idle(t, id))).toEqual({ kind: "assistant", text: "150 €." });
    expect(lastAnswer(await say(t, id, `cite ${ref}`))).toEqual({ kind: "assistant", text: "Said here." });
    expect((await t.store.getChat(id))?.knowledge_refs).toEqual([]);
  });

  it("strips the app's placeholder characters from answers", async () => {
    const { t } = setup();
    await configure(t);
    const id = await chatWith(t, "hello \uE000x\uE001 there");
    expect(lastAnswer(await idle(t, id)).text).toBe("Mock reply: hello x there");
  });

  it("the tools re-check at run time that the user is still an editor and the module on", async () => {
    const { t } = setup();
    expect((await tool({ ...toolCtx(t), userId: t.viewer.id }, "search_knowledge", { query: "die" })).ok).toBe(false);
    expect((await tool(toolCtx(t), "search_knowledge", { query: "die" })).ok).toBe(true);
    process.env.DISABLED_MODULES = "knowledge";
    expect((await tool(toolCtx(t), "read_knowledge", { documentId: "x" })).result.error).toMatch(/isn't available/);
  });

  const chunk = (text: string, facts: CitedChunk["facts"] = []): CitedChunk => ({ chunkId: 1, documentId: "d", name: "n", path: "p", page: 1, text, facts });

  it("checks whole markers only, normalizes spaced ones, and leaves a half-written one", () => {
    const allowed = new Set([1, 2]);
    const known = new Map([[1, chunk("Quote one.")]]);
    const source = { ref: "k:1", chunkId: 1, documentId: "d", name: "n", path: "p", page: 1, quote: "Quote one.", excerpt: "Quote one." };
    expect(checkSources("A [[k:1]]. B [[k:2]] [[k:3]]. C [[k:", allowed, known)).toEqual({ text: "A [[k:1]]. B. C [[k:", sources: [source] });
    expect(checkSources("A [[ k: 1 ]] and [[k :1]]. B [[ k:3 ]]. [[k:1", allowed, known)).toEqual({
      text: "A [[k:1]] and [[k:1]]. B. [[k:1",
      sources: [source],
    });
    expect(checkSources("\uE000A [[k:1]]\uE001", allowed, known).text).toBe("A [[k:1]]");
    expect(citedIds("x [[k:5]] [[ k : 5 ]] [[k:6]] [[k:7")).toEqual([5, 6]);
    expect(checkSources("no markers", allowed, known)).toEqual({ text: "no markers", sources: [] });
  });

  it("the excerpt: the sentences that back the statement, else the first; a matching fact's quote", () => {
    const text =
      "Hausratversicherung der Familie Krug. Versichert ist der gesamte Hausrat in der Wohnung. " +
      "Die Kündigung ist mit einer Frist von drei Monaten zum Ende des Versicherungsjahres möglich.\n" +
      "Fahrräder sind bis 2000 Euro mitversichert.";
    expect(excerptOf(chunk(text), "You can cancel with three months' notice: Kündigungsfrist drei Monate")).toBe(
      "Die Kündigung ist mit einer Frist von drei Monaten zum Ende des Versicherungsjahres möglich.",
    );
    expect(excerptOf(chunk(text), "Bikes are covered up to 2000 euros (Fahrrader)")).toBe("Fahrräder sind bis 2000 Euro mitversichert.");
    expect(excerptOf(chunk(text), "Something else entirely")).toBe("Hausratversicherung der Familie Krug.");
    const fact = { text: "Notice period three months", quote: "Frist von drei Monaten zum Ende des Versicherungsjahres" };
    expect(excerptOf(chunk(text, [fact]), "The notice period is three months (drei Monaten)")).toBe(fact.quote);
    // Always a part of the chunk, at most 300 characters.
    const long = "Wort ".repeat(200) + "Ende.";
    const e = excerptOf(chunk(long), "Wort");
    expect(e.length).toBeLessThanOrEqual(EXCERPT_MAX);
    expect(long.includes(e)).toBe(true);
    expect(statementBefore("First one. The deductible is 150 € [[k:1]] [[ k:2 ]]", 52)).toBe("The deductible is 150 €");
  });
});
