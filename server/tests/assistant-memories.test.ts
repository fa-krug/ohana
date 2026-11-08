// The assistant's memory (lib/assistant/memories.ts): the family's standing instructions by
// module, the /ai/memories routes, edit_memories (lib/assistant/tools/memory.ts: a card the user
// confirms, applied by the app through the routes, answered with POST …/memories), the chat's
// instructions listing them, and the categorizer following the finance ones.

import { afterEach, describe, expect, it } from "vitest";
import { cleanContext, systemPrompt } from "@/lib/assistant/chat";
import type { NetOptions } from "@/lib/assistant/net";
import { prepareTurn } from "@/lib/assistant/routes";
import type { ChatRow } from "@/lib/assistant/store";
import { runTool, type ToolContext, TOOLS, toolsFor } from "@/lib/assistant/tools";
import { memoriesSummary, resolveMemoryOps } from "@/lib/assistant/tools/memory";
import { createToken } from "@/lib/auth/tokens";
import { DrizzleCalendarStore, type FamilyRow } from "@/lib/calendar/store";
import { aiMemories } from "@/lib/db/schema";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { type AssistantTest, assistantTest, configure, type Event, net } from "@/lib/test/assistant";
import { makeUser, NOW } from "@/lib/test/factories";

let current: AssistantTest[] = [];
afterEach(async () => {
  await Promise.all(current.map((t) => t.stop()));
  current = [];
  delete process.env.DISABLED_MODULES;
});

function setup(worker = false) {
  const t = assistantTest({ worker });
  current.push(t);
  return t;
}

const mem = (t: AssistantTest) => `${t.ai}/memories`;
const add = async (t: AssistantTest, module: string, text: string) => {
  const res = await t.call("POST", mem(t), { module, text });
  expect(res.status, JSON.stringify(res.data)).toBe(201);
  return res.data;
};
const list = async (t: AssistantTest, query = "") => (await t.call("GET", mem(t) + query)).data.memories;

function toolCtx(t: AssistantTest, lang: "en" | "de" = "en"): ToolContext {
  return {
    lang,
    calendar: new DrizzleCalendarStore(t.db),
    finance: new DrizzleFinanceStore(t.db),
    db: t.db,
    familyId: t.familyId,
    net: {} as NetOptions,
    search: null,
    userId: t.editor.id,
    today: "2026-11-08",
  };
}

describe("the memory routes", () => {
  it("add, list, change and remove memories", async () => {
    const t = setup();
    const kids = await add(t, "finance", "  Clothing from Kidstore goes to Kids.  ");
    expect(kids).toEqual({
      id: expect.stringMatching(/^[0-9a-f-]{36}$/),
      module: "finance",
      text: "Clothing from Kidstore goes to Kids.",
      createdAt: expect.any(String),
      updatedAt: kids.createdAt,
      createdBy: { id: t.editor.id, name: "editor" },
    });
    const vacations = await add(t, "calendar", "School holidays count as vacation.");
    const general = await add(t, "general", "Answer in short sentences.");
    const second = await add(t, "finance", "Rent is housing.");
    // By module (general, calendar, finance …), then oldest first; viewers read them too.
    expect((await list(t)).map((m: { id: string }) => m.id)).toEqual([general.id, vacations.id, kids.id, second.id]);
    expect((await t.view("GET", mem(t))).data.memories).toHaveLength(4);
    expect((await list(t, "?module=finance")).map((m: { id: string }) => m.id)).toEqual([kids.id, second.id]);
    expect((await list(t, "?module=chores"))).toEqual([]);
    expect((await t.call("GET", mem(t) + "?module=weather")).status).toBe(400);

    const changed = await t.call("PATCH", `${mem(t)}/${kids.id}`, { text: "Clothing from Kidstore: Kids", module: "general" });
    expect(changed.status, JSON.stringify(changed.data)).toBe(200);
    expect(changed.data).toMatchObject({ id: kids.id, module: "general", text: "Clothing from Kidstore: Kids", createdAt: kids.createdAt });
    expect((await t.call("PATCH", `${mem(t)}/${kids.id}`, {})).data.text).toBe("Clothing from Kidstore: Kids");
    expect((await t.call("PATCH", `${mem(t)}/${kids.id}`, { text: "" })).status).toBe(400);
    expect((await t.call("PATCH", `${mem(t)}/${kids.id}`, { module: "weather" })).status).toBe(400);

    const gone = await t.call("DELETE", `${mem(t)}/${second.id}`);
    expect([gone.status, gone.data]).toEqual([200, { deleted: second.id }]);
    expect((await t.call("DELETE", `${mem(t)}/${second.id}`)).status).toBe(404);
    expect((await t.call("PATCH", `${mem(t)}/${second.id}`, { text: "x" })).status).toBe(404);
    expect((await list(t)).map((m: { id: string }) => m.id)).toEqual([kids.id, general.id, vacations.id]);
  });

  it("check the text, the module and the limits", async () => {
    const t = setup();
    const post = (body: unknown) => t.call("POST", mem(t), body);
    expect((await post({ module: "finance", text: "   " })).status).toBe(400);
    expect((await post({ module: "finance", text: "x".repeat(301) })).status).toBe(400);
    expect((await post({ module: "finance", text: "x".repeat(300) })).status).toBe(201);
    expect((await post({ module: "weather", text: "x" })).status).toBe(400);
    expect((await post({ text: "x" })).status).toBe(400);
    expect((await post({ id: "not-a-uuid", module: "general", text: "x" })).status).toBe(400);
    for (let i = 1; i < 50; i++) await add(t, "finance", `Rule ${i}`);
    const full = await post({ module: "finance", text: "One more" });
    expect(full.status).toBe(400);
    expect(full.data.error).toMatch(/full/);
    // Another module has room; moving one into the full one doesn't.
    const other = await add(t, "meals", "No fish on Fridays.");
    expect((await t.call("PATCH", `${mem(t)}/${other.id}`, { module: "finance" })).status).toBe(400);
  });

  it("bring a memory back under its id, once", async () => {
    const t = setup();
    const m = await add(t, "chores", "The bins go out on Thursdays.");
    await t.call("DELETE", `${mem(t)}/${m.id}`);
    const back = await t.call("POST", mem(t), { id: m.id, module: "chores", text: m.text });
    expect([back.status, back.data.id]).toEqual([201, m.id]);
    expect((await t.call("POST", mem(t), { id: m.id, module: "chores", text: "Again" })).status).toBe(409);
  });

  it("are the editors' to change, the members' to read", async () => {
    const t = setup();
    const m = await add(t, "general", "Call us the Krugs.");
    expect((await t.view("POST", mem(t), { module: "general", text: "x" })).status).toBe(403);
    expect((await t.view("PATCH", `${mem(t)}/${m.id}`, { text: "x" })).status).toBe(403);
    expect((await t.view("DELETE", `${mem(t)}/${m.id}`)).status).toBe(403);
    const stranger = makeUser(t.db, { email: "stranger@test" });
    const as = t.as(createToken(t.db, { userId: stranger.id, kind: "api" }, NOW).token);
    expect((await as("GET", mem(t))).status).toBe(404);
    expect((await as("POST", mem(t), { module: "general", text: "x" })).status).toBe(404);
    expect((await as("DELETE", `${mem(t)}/${m.id}`)).status).toBe(404);
    expect((await t.call("GET", mem(t))).data.memories).toHaveLength(1);
  });

  it("leave out the modules the server turned off", async () => {
    const t = setup();
    await add(t, "finance", "Rent is housing.");
    const kept = await add(t, "calendar", "Mondays are short.");
    process.env.DISABLED_MODULES = "finance,chores";
    expect((await list(t)).map((m: { id: string }) => m.id)).toEqual([kept.id]);
    expect(await list(t, "?module=finance")).toEqual([]);
    expect((await t.call("POST", mem(t), { module: "finance", text: "x" })).status).toBe(400);
    // General and the calendar are always there.
    process.env.DISABLED_MODULES = "finance,meals,appointments,chores,knowledge";
    expect((await t.call("POST", mem(t), { module: "general", text: "x" })).status).toBe(201);
  });
});

describe("edit_memories", () => {
  const run = (t: AssistantTest, args: unknown, lang: "en" | "de" = "en") =>
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    runTool("edit_memories", JSON.stringify(args), toolCtx(t, lang), new Set(Object.keys(TOOLS))) as Promise<any>;
  const errorOf = (t: AssistantTest, ops: unknown) => {
    try {
      resolveMemoryOps(toolCtx(t), ops);
    } catch (e) {
      return (e as Error).message;
    }
    return "ok";
  };

  it("offers the changes, resolved, and writes nothing", async () => {
    const t = setup();
    const rent = await add(t, "finance", "Rent is housing.");
    const fish = await add(t, "meals", "No fish.");
    const res = await run(t, {
      ops: [
        { action: "add", module: "finance", text: "  Clothing from Kidstore goes to Kids. " },
        { action: "update", id: rent.id, text: "Rent and parking are housing." },
        { action: "remove", id: fish.id },
      ],
    });
    expect(res.ok, JSON.stringify(res.result)).toBe(true);
    expect(res.result).toEqual({ waiting: true });
    expect(res.change).toBeUndefined();
    expect(res.memories).toEqual({
      summary: "Memory: 1 new, 1 changed, 1 forgotten",
      ops: [
        { action: "add", module: "finance", text: "Clothing from Kidstore goes to Kids." },
        { action: "update", id: rent.id, module: "finance", text: "Rent and parking are housing.", old: { module: "finance", text: "Rent is housing." } },
        { action: "remove", id: fish.id, module: "meals", text: "No fish.", old: { module: "meals", text: "No fish." } },
      ],
    });
    expect(t.db.select().from(aiMemories).all()).toHaveLength(2);
    expect((await list(t)).map((m: { text: string }) => m.text)).toEqual(["Rent is housing.", "No fish."]);
    // A module of its own only.
    const moved = await run(t, { ops: [{ action: "update", id: fish.id, module: "general" }] }, "de");
    expect(moved.memories).toEqual({
      summary: "Gemerktes ändern: „No fish.“",
      ops: [{ action: "update", id: fish.id, module: "general", text: "No fish.", old: { module: "meals", text: "No fish." } }],
    });
  });

  it("sums the changes up for the card", () => {
    const a = { action: "add" as const, module: "finance" as const, text: "Rent is housing." };
    expect(memoriesSummary([a], "en")).toBe("Remember “Rent is housing.”");
    expect(memoriesSummary([a], "de")).toBe("Merken: „Rent is housing.“");
    expect(memoriesSummary([{ ...a, action: "remove", id: "x" }], "en")).toBe("Forget “Rent is housing.”");
    expect(memoriesSummary([a, a], "de")).toBe("Gedächtnis: 2 neu");
  });

  it("refuses changes the memory wouldn't take", async () => {
    const t = setup();
    const rent = await add(t, "finance", "Rent is housing.");
    expect(errorOf(t, [])).toBe("ops must be a list of changes");
    expect(errorOf(t, Array.from({ length: 21 }, (_, i) => ({ action: "add", module: "general", text: `x${i}` })))).toMatch(/At most 20/);
    expect(errorOf(t, [{ action: "add", module: "weather", text: "x" }])).toMatch(/^ops\[0\]: module must be one of general, calendar/);
    expect(errorOf(t, [{ action: "add", module: "general", text: " " }])).toBe("ops[0]: text must be 1 to 300 characters");
    expect(errorOf(t, [{ action: "keep", id: rent.id }])).toMatch(/^ops\[0\]: action must be/);
    expect(errorOf(t, [{ action: "remove", id: "nope" }])).toBe('ops[0]: No memory "nope"');
    expect(errorOf(t, [{ action: "update", id: rent.id }])).toBe("ops[0]: give a new text or module");
    expect(errorOf(t, [{ action: "remove", id: rent.id }, { action: "update", id: rent.id, text: "x" }])).toMatch(/^ops\[1\]: .*changed twice/);
    // No duplicates: update the one there is.
    expect(errorOf(t, [{ action: "add", module: "finance", text: "rent  is HOUSING." }])).toBe(`This is remembered already (${rent.id}): update that one instead`);
    expect(errorOf(t, [{ action: "add", module: "general", text: "Rent is housing." }])).toBe("ok");
    expect(errorOf(t, [{ action: "remove", id: rent.id }, { action: "add", module: "finance", text: "Rent is housing." }])).toBe("ok");
    // The limit counts what the changes add.
    for (let i = 1; i < 49; i++) await add(t, "finance", `Rule ${i}`);
    expect(errorOf(t, [{ action: "add", module: "finance", text: "One" }])).toBe("ok");
    expect(errorOf(t, [{ action: "add", module: "finance", text: "One" }, { action: "add", module: "finance", text: "Two" }])).toMatch(/too full/);
    expect(errorOf(t, [{ action: "remove", id: rent.id }, { action: "add", module: "finance", text: "One" }, { action: "add", module: "finance", text: "Two" }])).toBe("ok");
    // A module the server turned off.
    process.env.DISABLED_MODULES = "finance";
    expect(errorOf(t, [{ action: "remove", id: rent.id }])).toBe(`ops[0]: No memory "${rent.id}"`);
    const res = await run(t, { ops: [{ action: "add", module: "finance", text: "x" }] });
    expect([res.ok, res.memories]).toEqual([false, undefined]);
  });

  it("isn't offered without changes, and lists only the modules on", () => {
    const tool = (writes: boolean) => toolsFor({ writes, search: false }).find((x) => x.function.name === "edit_memories");
    expect(tool(false)).toBeUndefined();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const modules = () => (tool(true)!.function.parameters as any).properties.ops.items.properties.module.enum;
    expect(modules()).toEqual(["general", "calendar", "finance", "meals", "appointments", "chores", "knowledge"]);
    process.env.DISABLED_MODULES = "finance,knowledge,assistant";
    expect(modules()).toEqual(["general", "calendar", "meals", "appointments", "chores"]);
  });
});

describe("memories in a chat", () => {
  const CONTEXT = { today: "2026-11-08", year: 2026, lang: "en", page: "finance" };
  async function chatWith(t: AssistantTest, text: string) {
    const res = await t.call("POST", `${t.ai}/chats`, { ...CONTEXT, text });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    return (res.data as Event[])[0].data.id as string;
  }
  async function items(t: AssistantTest, id: string) {
    for (let i = 0; i < 500; i++) {
      const res = await t.call("GET", `${t.ai}/chats/${id}`);
      if (res.data.chat.status === "idle") return res.data.items as any[]; // eslint-disable-line @typescript-eslint/no-explicit-any
      await new Promise((r) => setTimeout(r, 10));
    }
    throw new Error("The chat kept running");
  }
  const toolMessage = (t: AssistantTest, id: string, callId: string) =>
    t.store.listChatMessages(id).then((rows) => rows.map((r) => r.message).find((m) => m.role === "tool" && m.tool_call_id === callId));

  it("waits for the user's OK; the app applies it and the turn goes on with the results", async () => {
    const t = setup(true);
    await configure(t);
    const id = await chatWith(t, "remember finance: Clothing from Kidstore goes to Kids.");
    let shown = await items(t, id);
    const edit = shown.at(-1);
    expect(edit).toEqual({
      kind: "memories",
      id: expect.any(String),
      summary: "Remember “Clothing from Kidstore goes to Kids.”",
      ops: [{ action: "add", module: "finance", text: "Clothing from Kidstore goes to Kids." }],
    });
    expect(await list(t)).toEqual([]);
    expect((await t.call("POST", `${t.ai}/chats/${id}/suggestions`, { id: edit.id, applied: false, ...CONTEXT })).status).toBe(409);
    expect((await t.call("POST", `${t.ai}/chats/${id}/memories`, { id: "nope", applied: false, ...CONTEXT })).status).toBe(409);

    // The app applies it through the routes, then answers.
    const made = await add(t, "finance", edit.ops[0].text);
    const res = await t.call("POST", `${t.ai}/chats/${id}/memories`, {
      id: edit.id,
      applied: true,
      results: [{ ok: true, id: made.id }],
      ...CONTEXT,
    });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    shown = await items(t, id);
    expect(shown.find((it) => it.id === edit.id).answer).toEqual({ applied: true, results: [{ ok: true, id: made.id }] });
    expect(shown.at(-1)).toEqual({ kind: "assistant", text: "Done: 1 of 1 memory changes applied." });
    expect(JSON.parse(String((await toolMessage(t, id, edit.id))?.content))).toEqual({
      applied: true,
      results: [{ op: "add", title: "Clothing from Kidstore goes to Kids.", ok: true, id: made.id }],
    });

    // The next turn's instructions list it; forgetting it goes through a card too.
    const next = await chatWith(t, `forget ${made.id}`);
    expect(net.aiBody.messages[0].content).toContain(`Finances (finance):\n- ${made.id}: Clothing from Kidstore goes to Kids.`);
    const forget = (await items(t, next)).at(-1);
    expect(forget.ops).toEqual([
      { action: "remove", id: made.id, module: "finance", text: made.text, old: { module: "finance", text: made.text } },
    ]);
    await t.call("POST", `${t.ai}/chats/${next}/memories`, {
      id: forget.id,
      applied: true,
      results: [{ ok: false, declined: true }],
      ...CONTEXT,
    });
    expect(JSON.parse(String((await toolMessage(t, next, forget.id))?.content))).toEqual({
      applied: true,
      results: [{ op: "remove", title: made.text, ok: false, declined: true }],
    });
    expect(await list(t)).toHaveLength(1);
  });

  it("tells the model when the user declined, or wrote something else", async () => {
    const t = setup(true);
    await configure(t);
    const id = await chatWith(t, "remember general: Call us the Krugs.");
    const edit = (await items(t, id)).at(-1);
    await t.call("POST", `${t.ai}/chats/${id}/memories`, { id: edit.id, applied: false, ...CONTEXT });
    const shown = await items(t, id);
    expect(shown.find((it) => it.id === edit.id).answer).toEqual({ applied: false });
    expect(shown.at(-1).text).toBe("OK, I left your memories as they were.");
    expect(JSON.parse(String((await toolMessage(t, id, edit.id))?.content))).toEqual({
      applied: false,
      note: "The user declined these changes: nothing was changed in the family's memory.",
    });

    const other = await chatWith(t, "remember general: Call us the Krugs.");
    const waiting = (await items(t, other)).at(-1);
    await t.call("POST", `${t.ai}/chats/${other}/messages`, { text: "never mind", ...CONTEXT });
    expect((await items(t, other)).find((it) => it.id === waiting.id).skipped).toBe(true);
    expect(JSON.parse(String((await toolMessage(t, other, waiting.id))?.content))).toEqual({
      skipped: true,
      note: "The user neither applied nor declined these changes and wrote a new message instead: nothing was changed in the family's memory.",
    });
  });

  it("isn't offered to viewers, who still get the memories to follow", async () => {
    const t = setup(true);
    await configure(t);
    await add(t, "general", "Call us the Krugs.");
    const res = await t.view("POST", `${t.ai}/chats`, { text: "remember general: x", ...CONTEXT });
    expect(res.status).toBe(200);
    const sent = (net.aiBody.tools ?? []).map((x: { function: { name: string } }) => x.function.name);
    expect(sent).not.toContain("edit_memories");
    expect(net.aiBody.messages[0].content).toMatch(/## Memory\nThe family's standing instructions, by page: follow them\.\nGeneral \(general\):\n- [0-9a-f-]{36}: Call us the Krugs\./);
    expect(net.aiBody.messages[0].content).toContain("Memories can't be saved or changed from this chat.");
    expect(net.aiBody.messages[0].content).not.toContain("Offer to remember");
  });
});

describe("the chat's instructions", () => {
  async function system(t: AssistantTest, user = t.editor.id) {
    const family = (await new DrizzleCalendarStore(t.db).getFamily(t.familyId))!;
    const context = cleanContext({ today: "2026-11-08", year: 2026, lang: "en", page: "finance" });
    return (await prepareTurn(t.env, { user_id: user } as ChatRow, family, context)).system;
  }

  it("list the memories by module, without the modules turned off", async () => {
    const t = setup();
    await configure(t);
    const kids = await add(t, "finance", "Clothing from Kidstore goes to Kids.");
    const bins = await add(t, "chores", "Bins:\n  Thursdays.");
    const general = await add(t, "general", "Answer briefly.");
    let prompt = await system(t);
    expect(prompt).toContain(
      `## Memory\nThe family's standing instructions, by page: follow them.\nGeneral (general):\n- ${general.id}: Answer briefly.\n` +
        `Finances (finance):\n- ${kids.id}: Clothing from Kidstore goes to Kids.\nChores (chores):\n- ${bins.id}: Bins: Thursdays.\n`,
    );
    expect(prompt).toContain("Offer to remember (edit_memories");
    process.env.DISABLED_MODULES = "chores";
    prompt = await system(t);
    expect(prompt).not.toContain("Bins");
    expect(prompt).toContain(kids.id);
    // With changes off: followed, not changed.
    await configure(t, { allowWrites: false });
    prompt = await system(t);
    expect(prompt).toContain(kids.id);
    expect(prompt).toContain("Memories can't be saved or changed from this chat.");
  });

  it("say there's nothing yet, and leave the section out where nothing could be added", () => {
    const base = {
      family: { name: "Krug" } as FamilyRow,
      types: [], categories: [], accounts: [], currency: "EUR",
      today: "2026-11-08", year: 2026, page: "calendar", lang: "en", search: false,
    };
    expect(systemPrompt({ ...base, writes: true })).toContain("## Memory\nThe family's standing instructions, by page: follow them.\n(nothing yet)\nOffer to remember");
    expect(systemPrompt({ ...base, writes: false })).not.toContain("## Memory");
  });
});

describe("categorize with the finance memories", () => {
  async function addTransactions(t: AssistantTest, ops: unknown[]) {
    const res = await t.call("POST", `${t.f}/finance/transactions`, { ops });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    return res.data.added as string[];
  }
  async function categoryOf(t: AssistantTest, ids: string[]) {
    const res = await t.call("GET", `${t.f}/finance/transactions?limit=1000`);
    const byId = new Map(res.data.transactions.map((x: { id: string; categoryId: string | null }) => [x.id, x.categoryId]));
    return ids.map((id) => byId.get(id));
  }
  const EARLIER = [
    { date: "2026-01-02", amountCents: -3000, payee: "Kidstore", categoryId: "shopping" },
    { date: "2026-01-09", amountCents: -2000, payee: "Kidstore", categoryId: "shopping" },
    { date: "2026-01-10", amountCents: -4000, payee: "REWE Markt", categoryId: "groceries" },
  ];
  const NEW = [
    { date: "2026-02-01", amountCents: -2500, payee: "Kidstore" },
    { date: "2026-02-02", amountCents: -1500, payee: "REWE Markt" },
    { date: "2026-02-03", amountCents: -999, payee: "Something odd" },
  ];

  it("send every row to the model with its usual category; the memory wins, the usual one fills in", async () => {
    const t = setup();
    await configure(t);
    await add(t, "finance", "Purchases at Kidstore go to Kids.");
    await add(t, "meals", "No fish on Kidstore days."); // not the categorizer's
    const ids = await addTransactions(t, [...EARLIER, ...NEW]);
    const res = await t.call("POST", `${t.ai}/categorize`, { from: "2026-02-01" });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    expect([res.data.changed, res.data.matched, res.data.considered, res.data.ai]).toEqual([2, 1, 3, true]);
    expect(res.data.assignments).toEqual([
      { id: ids[4], categoryId: "groceries", source: "similar" },
      { id: ids[3], categoryId: "kids", source: "ai" },
    ]);
    expect((await categoryOf(t, ids)).slice(3)).toEqual(["kids", "groceries", null]);
    const [system, user] = net.aiBody.messages;
    expect(system.content).toContain("payee | description | usual category id");
    expect(system.content).toContain("The family's standing instructions (they come first):\n- Purchases at Kidstore go to Kids.\n");
    expect(system.content).not.toContain("No fish");
    expect(system.content).toMatch(/apply the standing instructions first/);
    expect(user.content).toBe(
      "1 | 2026-02-03 | -9.99 | Something odd |  | -\n2 | 2026-02-02 | -15.00 | REWE Markt |  | groceries\n3 | 2026-02-01 | -25.00 | Kidstore |  | shopping",
    );
    // Undo puts all of them back.
    await t.call("POST", `${t.f}/finance/transactions`, { ops: res.data.inverse });
    expect((await categoryOf(t, ids)).slice(3)).toEqual([null, null, null]);
  });

  it("stays as it was without finance memories", async () => {
    const t = setup();
    await configure(t);
    await add(t, "general", "Purchases at Kidstore go to Kids.");
    const ids = await addTransactions(t, [...EARLIER, ...NEW]);
    const res = await t.call("POST", `${t.ai}/categorize`, { from: "2026-02-01" });
    expect([res.data.changed, res.data.matched]).toEqual([2, 2]);
    expect((await categoryOf(t, ids)).slice(3)).toEqual(["shopping", "groceries", null]);
    expect(net.aiBody.messages[0].content).not.toContain("standing instructions");
    expect(net.aiBody.messages[1].content).toBe("1 | 2026-02-03 | -9.99 | Something odd | ");
  });
});
