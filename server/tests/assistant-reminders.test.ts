// The assistant's Reminders tools (lib/assistant/tools/reminders.ts): the snapshot the app sends
// with every message (`reminders` in the chat's context), get_reminders, and edit_reminders,
// which waits for the user to apply or decline the change in the app (POST …/reminders) like a
// question waits for its answer.

import { afterEach, describe, expect, it } from "vitest";
import { cleanContext } from "@/lib/assistant/chat";
import type { NetOptions } from "@/lib/assistant/net";
import { runTool, type ToolContext, TOOLS, toolsFor } from "@/lib/assistant/tools";
import { cleanReminders, editSummary, resolveOps } from "@/lib/assistant/tools/reminders";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { type AssistantTest, assistantTest, configure, type Event, net } from "@/lib/test/assistant";

let current: AssistantTest[] = [];
afterEach(async () => {
  await Promise.all(current.map((t) => t.stop()));
  current = [];
});

const REMINDERS = {
  shoppingListId: "L-shop",
  lists: [
    { id: "L-shop", title: "Groceries" },
    { id: "L-home", title: "Home" },
  ],
  items: [
    { id: "R1", list: "L-shop", title: "Milk", due: "2026-11-07", completed: false },
    { id: "R2", list: "L-home", title: "Call grandma", notes: "Birthday", due: "2026-11-03T18:30" },
  ],
};
const snapshot = () => cleanReminders(REMINDERS)!;
const CONTEXT = { today: "2026-11-02", year: 2026, lang: "en", page: "meals" };

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Res = { ok: boolean; result: any; summary: string; reminders?: any };

function toolCtx(t: AssistantTest, reminders = snapshot(), lang: "en" | "de" = "en"): ToolContext {
  return {
    lang,
    calendar: new DrizzleCalendarStore(t.db),
    finance: new DrizzleFinanceStore(t.db),
    db: t.db,
    familyId: t.familyId,
    net: {} as NetOptions,
    search: null,
    userId: t.editor.id,
    today: CONTEXT.today,
    reminders,
  };
}

async function setup(worker = true) {
  const t = assistantTest({ worker });
  current.push(t);
  return t;
}

describe("the Reminders in the chat's context", () => {
  it("are checked and capped", () => {
    expect(cleanReminders(undefined)).toBeUndefined();
    expect(cleanReminders("x")).toBeUndefined();
    expect(cleanReminders([])).toBeUndefined();
    const r = cleanReminders({
      shoppingListId: "gone",
      lists: [
        ...Array.from({ length: 120 }, (_, i) => ({ id: `L${i}`, title: `List ${i}` })),
        { id: "L0", title: "Twice" },
      ],
      items: [
        { id: "a", list: "L0", title: "x".repeat(300), notes: "n".repeat(1500), due: "2026-02-30" },
        { id: "b", list: "L-unknown", title: "No list" },
        { id: "a", list: "L0", title: "Twice" },
        { id: "c", list: "L1", title: "Done", due: "2026-11-02T25:00", completed: true },
        { list: "L1", title: "No id" },
        ...Array.from({ length: 600 }, (_, i) => ({ id: `i${i}`, list: "L2", title: `Item ${i}`, due: "2026-11-02T09:15" })),
      ],
    })!;
    expect(r.shoppingListId).toBeNull();
    expect(r.lists).toHaveLength(100);
    expect(r.lists[0]).toEqual({ id: "L0", title: "List 0" });
    expect(r.items).toHaveLength(500);
    expect(r.items[0]).toEqual({ id: "a", list: "L0", title: "x".repeat(200), notes: "n".repeat(1000), due: null });
    expect(r.items[1]).toEqual({ id: "c", list: "L1", title: "Done", due: null, completed: true });
    expect(r.items[2]).toEqual({ id: "i0", list: "L2", title: "Item 0", due: "2026-11-02T09:15" });
    expect(snapshot().shoppingListId).toBe("L-shop");
  });

  it("are kept in the context only when the app sent them", () => {
    expect(cleanContext({ ...CONTEXT })).not.toHaveProperty("reminders");
    expect(cleanContext({ ...CONTEXT, reminders: REMINDERS }).reminders).toEqual(snapshot());
  });
});

describe("the Reminders tools", () => {
  it("are offered only with the user's Reminders, and to viewers only for reading", () => {
    const names = (opts: Parameters<typeof toolsFor>[0]) => toolsFor(opts).map((t) => t.function.name);
    expect(names({ writes: true, search: false })).not.toContain("get_reminders");
    expect(names({ writes: true, search: false })).not.toContain("edit_reminders");
    expect(names({ writes: true, search: false, reminders: true })).toEqual(expect.arrayContaining(["get_reminders", "edit_reminders"]));
    const read = names({ writes: false, search: false, reminders: true });
    expect(read).toContain("get_reminders");
    expect(read).not.toContain("edit_reminders");
  });

  it("read the lists and open reminders, of one list too", async () => {
    const t = await setup(false);
    const tool = async (args: unknown, ctx = toolCtx(t)) =>
      (await runTool("get_reminders", JSON.stringify(args), ctx, new Set(Object.keys(TOOLS)))) as Res;
    const all = await tool({});
    expect(all.result.shoppingList).toEqual({ id: "L-shop", title: "Groceries" });
    expect(all.result.lists).toEqual([
      { id: "L-shop", title: "Groceries", shopping: true, open: 1 },
      { id: "L-home", title: "Home", open: 1 },
    ]);
    expect(all.result.items.map((i: { id: string }) => i.id)).toEqual(["R1", "R2"]);
    expect(all.result.items[1]).toEqual({ id: "R2", list: "L-home", title: "Call grandma", notes: "Birthday", due: "2026-11-03T18:30" });
    expect((await tool({ list: "shopping" })).result.items.map((i: { id: string }) => i.id)).toEqual(["R1"]);
    expect((await tool({ list: "home" })).result.items.map((i: { id: string }) => i.id)).toEqual(["R2"]);
    expect((await tool({ list: "Work" })).result.error).toMatch(/No Reminders list "Work"/);
    const without = { ...toolCtx(t), reminders: undefined };
    expect((await runTool("get_reminders", "{}", without, new Set(Object.keys(TOOLS)))).result).toEqual({
      error: "The user's Reminders aren't available in this chat",
    });
  });

  it("resolve an edit's ops against the snapshot", () => {
    const r = snapshot();
    expect(
      resolveOps(r, [
        { op: "add", list: "shopping", title: " Bread ", due: "2026-11-07" },
        { op: "add", list: "home", title: "Fix the door", notes: "Hinge", due: "2026-11-04T10:00" },
        { op: "add", list: "L-home", title: "Water plants" },
        { op: "update", id: "R2", due: null, list: "Groceries" },
        { op: "update", id: "R1", title: "Oat milk" },
        { op: "complete", id: "R1" },
        { op: "uncomplete", id: "R1" },
        { op: "delete", id: "R2" },
      ]),
    ).toEqual([
      { op: "add", list: "L-shop", listTitle: "Groceries", title: "Bread", due: "2026-11-07" },
      { op: "add", list: "L-home", listTitle: "Home", title: "Fix the door", notes: "Hinge", due: "2026-11-04T10:00" },
      { op: "add", list: "L-home", listTitle: "Home", title: "Water plants" },
      { op: "update", id: "R2", itemTitle: "Call grandma", list: "L-shop", listTitle: "Groceries", due: null },
      { op: "update", id: "R1", itemTitle: "Milk", list: "L-shop", listTitle: "Groceries", title: "Oat milk" },
      { op: "complete", id: "R1", itemTitle: "Milk", list: "L-shop", listTitle: "Groceries" },
      { op: "uncomplete", id: "R1", itemTitle: "Milk", list: "L-shop", listTitle: "Groceries" },
      { op: "delete", id: "R2", itemTitle: "Call grandma", list: "L-home", listTitle: "Home" },
    ]);
  });

  it("refuse ops that don't fit the snapshot", () => {
    const r = snapshot();
    const err = (ops: unknown) => {
      try {
        resolveOps(r, ops);
      } catch (e) {
        return (e as Error).message;
      }
      return "ok";
    };
    expect(err([])).toMatch(/1 to 50 changes/);
    expect(err(Array.from({ length: 51 }, () => ({ op: "add", list: "Home", title: "x" })))).toMatch(/1 to 50/);
    expect(err([{ op: "complete", id: "R9" }])).toBe('ops[0]: No reminder with the id "R9" (get_reminders gives the ids)');
    expect(err([{ op: "add", list: "Home", title: "ok" }, { op: "delete" }])).toMatch(/^ops\[1\]: id is required/);
    expect(err([{ op: "add", list: "Work", title: "x" }])).toMatch(/^ops\[0\]: No Reminders list "Work". The lists are: “Groceries”, “Home”/);
    expect(err([{ op: "add", title: "x" }])).toBe("ops[0]: list is required");
    expect(err([{ op: "add", list: "Home", title: "  " }])).toBe("ops[0]: title must not be empty");
    expect(err([{ op: "add", list: "Home", title: "x".repeat(201) }])).toMatch(/at most 200/);
    expect(err([{ op: "add", list: "Home", title: "x", due: "tomorrow" }])).toMatch(/due must be/);
    expect(err([{ op: "update", id: "R1" }])).toMatch(/changes nothing/);
    expect(err([{ op: "move", id: "R1" }])).toMatch(/op must be add, update/);
    // "shopping" without a chosen shopping list, and a title two lists share.
    const none = { ...r, shoppingListId: null };
    expect(() => resolveOps(none, [{ op: "add", list: "shopping", title: "x" }])).toThrow(/No Reminders list is chosen/);
    const twice = { ...r, lists: [...r.lists, { id: "L-home2", title: "home" }] };
    expect(() => resolveOps(twice, [{ op: "add", list: "Home", title: "x" }])).toThrow(/Several lists are called "Home"/);
  });

  it("sum an edit up for the card", () => {
    const r = snapshot();
    const sum = (ops: unknown[], lang: "en" | "de" = "en") => editSummary(resolveOps(r, ops), lang);
    expect(sum([{ op: "add", list: "shopping", title: "Bread" }])).toBe("Add “Bread” to Groceries");
    expect(sum([{ op: "add", list: "shopping", title: "Brot" }], "de")).toBe("„Brot“ zu Groceries hinzufügen");
    const three = ["Bread", "Eggs", "Butter"].map((title) => ({ op: "add", list: "shopping", title }));
    expect(sum(three)).toBe("Add 3 reminders to Groceries");
    expect(sum(three, "de")).toBe("3 Erinnerungen zu Groceries hinzufügen");
    expect(sum([...three, { op: "complete", id: "R1" }, { op: "delete", id: "R2" }])).toBe(
      "Add 3 reminders, complete 1 reminder, delete 1 reminder",
    );
    expect(sum([{ op: "complete", id: "R1" }])).toBe("Complete “Milk”");
    expect(sum([{ op: "complete", id: "R1" }, { op: "complete", id: "R2" }], "de")).toBe("2 Erinnerungen abhaken");
  });

  it("edit_reminders gives the resolved change to wait for, not a result", async () => {
    const t = await setup(false);
    const res = await runTool(
      "edit_reminders",
      JSON.stringify({ ops: [{ op: "add", list: "shopping", title: "Bread" }] }),
      toolCtx(t),
      new Set(Object.keys(TOOLS)),
    );
    expect(res).toMatchObject({
      ok: true,
      result: { waiting: true },
      reminders: { summary: "Add “Bread” to Groceries", ops: [{ op: "add", list: "L-shop", listTitle: "Groceries", title: "Bread" }] },
    });
    const bad = await runTool("edit_reminders", JSON.stringify({ ops: [{ op: "delete", id: "nope" }] }), toolCtx(t), new Set(Object.keys(TOOLS)));
    expect(bad.ok).toBe(false);
    expect(bad.reminders).toBeUndefined();
  });
});

describe("a Reminders edit in a chat", () => {
  async function chatWith(t: AssistantTest, text: string, extra: Record<string, unknown> = { reminders: REMINDERS }) {
    const res = await t.call("POST", `${t.ai}/chats`, { text, ...CONTEXT, ...extra });
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

  it("waits for the user, and goes on once they applied it", async () => {
    const t = await setup();
    await configure(t);
    const id = await chatWith(t, "remind me to buy bread");
    expect(net.aiBody.messages[0].content).toMatch(/edit_reminders changes them \(to add groceries:\nlist "shopping"\)/);
    let list = await items(t, id);
    const edit = list.at(-1);
    expect(edit).toEqual({
      kind: "reminders",
      id: expect.any(String),
      summary: "Add “buy bread” to Groceries",
      ops: [{ op: "add", list: "L-shop", listTitle: "Groceries", title: "buy bread" }],
    });
    // It shows as the card, not as a tool call.
    expect(list.some((it) => it.kind === "tool")).toBe(false);
    // Only the waiting edit can be answered, and not as a question.
    expect((await t.call("POST", `${t.ai}/chats/${id}/reminders`, { id: "nope", applied: false, ...CONTEXT })).status).toBe(409);
    expect((await t.call("POST", `${t.ai}/chats/${id}/answer`, { id: edit.id, selected: ["x"], ...CONTEXT })).status).toBe(409);
    expect((await t.call("POST", `${t.ai}/chats/${id}/reminders`, { id: edit.id, applied: true, ...CONTEXT })).status).toBe(400);
    expect((await t.call("POST", `${t.ai}/chats/${id}/reminders`, { id: edit.id, ...CONTEXT })).status).toBe(400);

    const fresh = { ...REMINDERS, items: [...REMINDERS.items, { id: "R3", list: "L-shop", title: "buy bread", due: null }] };
    const res = await t.call("POST", `${t.ai}/chats/${id}/reminders`, {
      id: edit.id,
      applied: true,
      results: [{ ok: true, id: "R3", extra: "dropped" }],
      reminders: fresh,
      ...CONTEXT,
    });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    list = await items(t, id);
    expect(list.find((it) => it.kind === "reminders").answer).toEqual({ applied: true, results: [{ ok: true, id: "R3" }] });
    expect(list.at(-1)).toEqual({ kind: "assistant", text: "Done: 1 of 1 reminder changes applied." });
    expect(JSON.parse(String((await toolMessage(t, id, edit.id))?.content))).toEqual({
      applied: true,
      results: [{ op: "add", title: "buy bread", ok: true, id: "R3" }],
    });
    // The chat knows the reminders as they are now.
    const row = (await t.store.getChat(id))!;
    expect((row.context as { reminders: { items: unknown[] } }).reminders.items).toHaveLength(3);
    // It can't be answered twice.
    expect((await t.call("POST", `${t.ai}/chats/${id}/reminders`, { id: edit.id, applied: false, ...CONTEXT })).status).toBe(409);
  });

  it("tells the model when the user declined, and what failed", async () => {
    const t = await setup();
    await configure(t);
    const id = await chatWith(t, "complete R1");
    let edit = (await items(t, id)).at(-1);
    expect(edit).toMatchObject({ kind: "reminders", summary: "Complete “Milk”" });
    await t.call("POST", `${t.ai}/chats/${id}/reminders`, { id: edit.id, applied: false, reminders: REMINDERS, ...CONTEXT });
    let list = await items(t, id);
    expect(list.find((it) => it.id === edit.id).answer).toEqual({ applied: false });
    expect(list.at(-1).text).toBe("OK, I left your Reminders as they were.");
    expect(JSON.parse(String((await toolMessage(t, id, edit.id))?.content))).toEqual({
      applied: false,
      note: "The user declined these changes: nothing was changed in their Reminders.",
    });

    // Applied, but EventKit refused it; a missing result counts as failed.
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "complete R1", ...CONTEXT, reminders: REMINDERS });
    edit = (await items(t, id)).at(-1);
    await t.call("POST", `${t.ai}/chats/${id}/reminders`, { id: edit.id, applied: true, results: [], reminders: REMINDERS, ...CONTEXT });
    list = await items(t, id);
    expect(list.find((it) => it.id === edit.id).answer).toEqual({ applied: true, results: [{ ok: false, error: "No result" }] });
    expect(list.at(-1).text).toBe("Done: 0 of 1 reminder changes applied.");
  });

  it("is skipped by a new message, and errors go back to the model", async () => {
    const t = await setup();
    await configure(t);
    const id = await chatWith(t, "remind me to call the dentist in Home");
    const edit = (await items(t, id)).at(-1);
    expect(edit.ops[0]).toMatchObject({ list: "L-home", title: "call the dentist" });
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "never mind", ...CONTEXT, reminders: REMINDERS });
    const list = await items(t, id);
    expect(list.find((it) => it.id === edit.id).skipped).toBe(true);
    expect(JSON.parse(String((await toolMessage(t, id, edit.id))?.content))).toMatchObject({
      skipped: true,
      note: expect.stringMatching(/nothing was changed in their Reminders/),
    });
    expect((await t.call("POST", `${t.ai}/chats/${id}/reminders`, { id: edit.id, applied: true, results: [], ...CONTEXT })).status).toBe(409);

    // An unknown reminder: the model hears why, nothing waits.
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "complete R9", ...CONTEXT, reminders: REMINDERS });
    const after = await items(t, id);
    expect(after.filter((it) => it.kind === "reminders")).toHaveLength(1);
    expect(after.at(-1).text).toMatch(/^That didn't work: ops\[0\]: No reminder with the id "R9"/);
  });

  it("isn't offered to viewers or without the user's Reminders", async () => {
    const t = await setup();
    await configure(t);
    const res = await t.view("POST", `${t.ai}/chats`, { text: "remind me to buy bread", ...CONTEXT, reminders: REMINDERS });
    expect(res.status).toBe(200);
    let sent = (net.aiBody.tools ?? []).map((x: { function: { name: string } }) => x.function.name);
    expect(sent).toContain("get_reminders");
    expect(sent).not.toContain("edit_reminders");

    await chatWith(t, "reminders", {});
    sent = (net.aiBody.tools ?? []).map((x: { function: { name: string } }) => x.function.name);
    expect(sent).not.toContain("get_reminders");
    expect(sent).not.toContain("edit_reminders");
    expect(sent).toContain("get_shopping_items");
    expect(net.aiBody.messages[0].content).toMatch(/Reminders \(where the family's shopping list is\) aren't available/);
  });

  it("waits for one thing at a time: a question in the same step is refused", async () => {
    const t = await setup();
    await configure(t);
    const id = await chatWith(t, "ask and remind me to buy eggs");
    const list = await items(t, id);
    expect(list.filter((it) => it.kind === "question")).toHaveLength(0);
    const edit = list.at(-1);
    expect(edit).toMatchObject({ kind: "reminders", summary: "Add “buy eggs” to Groceries" });
    type Stored = { role: string; content?: unknown; tool_call_id?: string; tool_calls?: { id: string; function: { name: string } }[] };
    const rows = (await t.store.listChatMessages(id)).map((r) => r.message as unknown as Stored);
    const call = rows.find((m) => m.tool_calls?.length === 2)!;
    const ask = call.tool_calls!.find((c) => c.function.name === "ask_user")!;
    expect(String(rows.find((m) => m.tool_call_id === ask.id)?.content)).toMatch(/Ask one question at a time/);
    // The edit still waits, and goes on when answered.
    await t.call("POST", `${t.ai}/chats/${id}/reminders`, { id: edit.id, applied: false, reminders: REMINDERS, ...CONTEXT });
    expect((await items(t, id)).at(-1).text).toBe("OK, I left your Reminders as they were.");
  });

  it("comes along with an imported chat, checked", async () => {
    const t = await setup();
    const res = await t.call("POST", `${t.ai}/chats/import`, {
      title: "Old",
      items: [
        { kind: "user", text: "add bread" },
        {
          kind: "reminders",
          id: "c1",
          summary: "Add “Bread” to Groceries",
          ops: [{ op: "add", list: "L-shop", listTitle: "Groceries", title: "Bread" }, "junk"],
          answer: { applied: true, results: [{ ok: true, id: "R3", x: 1 }, { ok: false }] },
        },
        { kind: "reminders", id: "c2", summary: "Complete “Milk”", ops: [] },
      ],
      history: [],
    });
    expect(res.status, JSON.stringify(res.data)).toBe(201);
    const got = (await t.call("GET", `${t.ai}/chats/${res.data.chat.id}`)).data.items;
    expect(got[1]).toEqual({
      kind: "reminders",
      id: "c1",
      summary: "Add “Bread” to Groceries",
      ops: [{ op: "add", list: "L-shop", listTitle: "Groceries", title: "Bread" }],
      answer: { applied: true, results: [{ ok: true, id: "R3" }, { ok: false, error: "Failed" }] },
    });
    expect(got[2]).toMatchObject({ kind: "reminders", id: "c2", skipped: true });
  });
});
