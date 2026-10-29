// family-planner's tests/chats.test.ts: the AI chats kept on the server. In Ohana the turns run
// in the worker (the ChatRunner ticks every few milliseconds here), the web routes only save
// messages and follow the chat from the database; a worker that dies leaves a turn the next one
// takes over.

import { eq } from "drizzle-orm";
import { afterEach, describe, expect, it } from "vitest";
import { ChatRunner } from "@/lib/assistant/runner";
import { createToken } from "@/lib/auth/tokens";
import { chats, familyMembers } from "@/lib/db/schema";
import { type AssistantTest, assistantTest, configure, type Event, net } from "@/lib/test/assistant";
import { NOW, makeUser } from "@/lib/test/factories";
import type { AiEnv } from "@/lib/assistant/routes";

let current: AssistantTest[] = [];
afterEach(async () => {
  await Promise.all(current.map((t) => t.stop()));
  current = [];
});

async function setup(env: Partial<AiEnv> = {}, settings: Record<string, unknown> = {}, worker = true) {
  const t = assistantTest({ env, worker });
  current.push(t);
  await configure(t, settings);
  return t;
}

const CONTEXT = { today: "2026-03-10", year: 2026, lang: "en", page: "calendar" };

/** Starts a chat and reads its stream to the end. */
async function start(t: AssistantTest, text: string) {
  const res = await t.call("POST", `${t.ai}/chats`, { text, ...CONTEXT });
  expect(res.status, JSON.stringify(res.data)).toBe(200);
  const ev = res.data as Event[];
  return { ev, id: ev[0].data.id as string };
}

async function state(t: AssistantTest, id: string) {
  const res = await t.call("GET", `${t.ai}/chats/${id}`);
  expect(res.status, JSON.stringify(res.data)).toBe(200);
  return res.data as { chat: any; rev: number; items: any[] }; // eslint-disable-line @typescript-eslint/no-explicit-any
}

/** Waits until no turn runs in the chat (and none waits). */
async function idle(t: AssistantTest, id: string) {
  for (let i = 0; i < 1000; i++) {
    const s = await state(t, id);
    if (s.chat.status === "idle" && !s.chat.queued.length) return s;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error("The chat kept running");
}

/** The chat as the app builds it from a stream: items by position. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function replay(ev: Event[], items: any[] = []) {
  for (const e of ev) {
    if (e.event === "items") for (const { seq, item } of e.data.items) items[seq] = item;
  }
  return items;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const shown = (items: any[]) =>
  items
    .filter((it) => !(it.kind === "assistant" && !it.text))
    .map((it) => (it.kind === "assistant" || it.kind === "user" ? `${it.kind}: ${it.text}` : it.kind));

describe("assistant chats", () => {
  it("run in the worker and are kept for every device", async () => {
    const t = await setup();
    const { ev, id } = await start(t, "Add vacation from 2026-08-03 to 2026-08-07");
    expect(ev[0].event).toBe("chat");
    expect(ev[0].data.status).toBe("running");
    expect(ev.at(-1)!.event).toBe("end");
    const s = await state(t, id);
    expect(s.chat.status).toBe("idle");
    expect(s.chat.title).toBe("Add vacation from 2026-08-03 to 2026-08-07");
    expect(shown(s.items)).toEqual([
      "user: Add vacation from 2026-08-03 to 2026-08-07",
      "assistant: I'll add that.",
      "tool",
      "change",
      "assistant: Done: 5 days changed.",
    ]);
    // What the stream showed is what is stored.
    expect(shown(replay(ev))).toEqual(shown(s.items));
    const tool = s.items.find((it) => it.kind === "tool");
    expect([tool.name, tool.status]).toEqual(["change_entries", "ok"]);
    expect(tool.result).toMatch(/"changed":5/);
    const change = s.items.find((it) => it.kind === "change");
    expect([change.change, change.summary]).toEqual(["entries", "5 days changed"]);
    const entries = (await t.call("GET", `${t.f}/entries?year=2026`)).data;
    expect(Object.keys(entries)).toHaveLength(5);

    const list = (await t.call("GET", `${t.ai}/chats`)).data.chats;
    expect(list.map((c: { id: string; status: string }) => [c.id, c.status])).toEqual([[id, "idle"]]);

    // The next message: the model gets the whole chat back.
    const next = await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "thanks", ...CONTEXT });
    expect(next.status).toBe(200);
    expect(net.aiBody.messages.map((m: { role: string }) => m.role)).toEqual([
      "system",
      "user",
      "assistant",
      "tool",
      "assistant",
      "user",
    ]);
    expect(shown((await state(t, id)).items).slice(-2)).toEqual(["user: thanks", "assistant: Mock reply: thanks"]);

    // Following an idle chat: what changed since, then the end.
    const { rev } = await state(t, id);
    const same = (await t.call("GET", `${t.ai}/chats/${id}/events?since=${rev}`)).data as Event[];
    expect(same.map((e) => e.event)).toEqual(["chat", "end"]);
    const all = (await t.call("GET", `${t.ai}/chats/${id}/events?since=0`)).data as Event[];
    expect(replay(all)).toHaveLength(7);
  });

  it("stay on the page they started on until they are moved", async () => {
    const t = await setup();
    const { ev, id } = await start(t, "hello");
    expect(ev[0].data.page).toBe("calendar");
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "again", ...CONTEXT, page: "finance" });
    expect(net.aiBody.messages[0].content).toMatch(/This chat belongs to the calendar page/);
    expect((await state(t, id)).chat.page).toBe("calendar");

    expect((await t.call("POST", `${t.ai}/chats/${id}/page`, { page: "nowhere" })).status).toBe(400);
    const moved = await t.call("POST", `${t.ai}/chats/${id}/page`, { page: "finance" });
    expect(moved.status).toBe(200);
    expect(moved.data.chat.page).toBe("finance");
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "and now?", ...CONTEXT });
    expect(net.aiBody.messages[0].content).toMatch(/This chat belongs to the finance page/);
    expect((await t.call("GET", `${t.ai}/chats`)).data.chats[0].page).toBe("finance");
  });

  it("go on when the app is closed", async () => {
    const t = await setup();
    expect(await t.fire("POST", `${t.ai}/chats`, { text: "how much did we spend?", ...CONTEXT })).toBe(200);
    const id = (await t.call("GET", `${t.ai}/chats`)).data.chats[0].id;
    const s = await idle(t, id);
    expect(shown(s.items)).toEqual(["user: how much did we spend?", "tool", "assistant: Income 0, expenses 0."]);
  });

  it("wait for the worker: the web process never runs a turn", async () => {
    const t = await setup({}, {}, false);
    expect(await t.fire("POST", `${t.ai}/chats`, { text: "hello", ...CONTEXT })).toBe(200);
    const id = (await t.call("GET", `${t.ai}/chats`)).data.chats[0].id;
    await new Promise((r) => setTimeout(r, 50));
    let s = await state(t, id);
    expect(s.chat.status).toBe("running");
    expect(shown(s.items)).toEqual(["user: hello"]);
    // Running, held by nobody: the worker's next tick takes it.
    const row = t.db.select().from(chats).where(eq(chats.id, id)).get()!;
    expect([row.runToken, row.runUntil]).toEqual([null, null]);
    expect(t.runner.tick()).toBe(1);
    expect(t.runner.tick()).toBe(0); // taken already
    await t.runner.idle();
    s = await state(t, id);
    expect(shown(s.items)).toEqual(["user: hello", "assistant: Mock reply: hello"]);
  });

  it("are condensed for the model when long, and the next message still knows", async () => {
    const t = await setup({}, { contextWindow: 16000 });
    const { ev, id } = await start(t, "keep looking 40 times");
    let s = await state(t, id);
    expect(shown(s.items).at(-1)).toBe("assistant: Done looking: 40 times.");
    expect(s.items.filter((it) => it.kind === "tool")).toHaveLength(40);
    // The chat shows where it was condensed; the stream showed the same.
    expect(s.items.some((it) => it.kind === "compacted")).toBe(true);
    expect(shown(replay(ev))).toEqual(shown(s.items));
    // How full the context is, kept with the chat.
    expect(s.chat.usage.max).toBe(16000);
    expect(s.chat.usage.used > 0 && s.chat.usage.used < 16000).toBe(true);
    // The summary is kept among the messages; the next message builds on it.
    const stored = await t.store.listChatMessages(id);
    const marks = stored.filter((r) => r.message.role === "summary");
    expect(marks.length).toBeGreaterThanOrEqual(1);
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "how often?", ...CONTEXT });
    s = await state(t, id);
    expect(shown(s.items).at(-1)).toBe("assistant: Mock reply: how often?");
    const [, summary, next] = net.aiBody.messages;
    expect(summary.content).toMatch(/^\[What happened earlier[\s\S]*Looked \d+ times/);
    expect(next.role).toBe("assistant");
    expect(net.aiBody.messages.at(-1)).toEqual({ role: "user", content: "how often?" });
    // Everything after the summary is there, nothing went missing in between.
    const from = marks.at(-1)!.message.from as number;
    const after = stored.slice(from).filter((r) => r.message.role !== "summary");
    // The instructions, the summary, the messages after it, and the new one.
    expect(net.aiBody.messages).toHaveLength(2 + after.length + 1);
  });

  it("ask, and go on with the answer", async () => {
    const t = await setup({}, { allowWrites: false });
    const { id } = await start(t, "ask several");
    let s = await state(t, id);
    const q = s.items.at(-1);
    expect([s.chat.status, q.kind, q.multiple]).toEqual(["idle", "question", true]);
    // Only the open question can be answered.
    const wrong = await t.call("POST", `${t.ai}/chats/${id}/answer`, { id: "nope", selected: ["Beach"] });
    expect(wrong.status).toBe(409);
    const res = await t.call("POST", `${t.ai}/chats/${id}/answer`, {
      id: q.id,
      selected: ["Beach", "City", "Moon"],
      text: "A lake",
      ...CONTEXT,
    });
    expect(res.status).toBe(200);
    s = await state(t, id);
    expect(s.items.find((it) => it.kind === "question").answer).toEqual({ selected: ["Beach", "City"], text: "A lake" });
    expect(shown(s.items).at(-1)).toBe("assistant: You answered: Beach, City, A lake.");

    // A new message instead of an answer leaves the question unanswered.
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "ask", ...CONTEXT });
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "never mind", ...CONTEXT });
    s = await state(t, id);
    expect(s.items.filter((it) => it.kind === "question").at(-1).skipped).toBe(true);
    expect(net.aiBody.messages.some((m: { role: string; content: string }) => m.role === "tool" && /skipped/.test(m.content))).toBe(true);
  });

  it("end a stopped turn with what it did", async () => {
    const t = await setup();
    expect(await t.fire("POST", `${t.ai}/chats`, { text: "take your time", ...CONTEXT })).toBe(200);
    const id = (await t.call("GET", `${t.ai}/chats`)).data.chats[0].id;
    // While it runs, no other message.
    const busy = await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "hi", ...CONTEXT });
    expect(busy.status).toBe(409);
    expect((await t.call("POST", `${t.ai}/chats/${id}/stop`)).status).toBe(200);
    const s = await idle(t, id);
    expect(shown(s.items)).toEqual(["user: take your time"]);
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "hello", ...CONTEXT });
    expect(net.aiBody.messages.slice(1)).toEqual([
      { role: "user", content: "take your time" },
      { role: "assistant", content: "(stopped)" },
      { role: "user", content: "hello" },
    ]);
  });

  it("try a failed step again, and give up after five tries", async () => {
    const t = await setup();
    let { id } = await start(t, "calendar, then fail 2 times");
    let s = await state(t, id);
    expect(shown(s.items)).toEqual(["user: calendar, then fail 2 times", "tool", `assistant: ${s.items.at(-1).text}`]);
    expect(s.items.at(-1).text).toMatch(/Here is what I found/);

    ({ id } = await start(t, "keep looking, then fail"));
    s = await state(t, id);
    expect(s.items.at(-1).kind).toBe("error");
    expect(s.items.at(-1).text).toMatch(/503/);
    // The history stays valid for the next message.
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "ok", ...CONTEXT });
    expect(net.aiBody.messages.at(-2).role).toBe("assistant");
    expect(net.aiBody.messages.at(-2).content).toMatch(/No answer/);
  });

  it("are taken over by the next worker when the one running the turn died", async () => {
    const t = await setup({ leaseMs: 50 });
    const { id } = await start(t, "hello");
    // As if a worker died in the middle of a step: its tool call is shown but not saved for the
    // model, and nobody renews the chat.
    t.db
      .update(chats)
      .set({ status: "running", runToken: "dead", runUntil: new Date(Date.now() - 1000) })
      .where(eq(chats.id, id))
      .run();
    await t.store.addChatMessages(id, [{ seq: 2, message: { role: "user", content: "calendar" } }]);
    await t.store.putChatItems(id, [
      { seq: 2, item: { kind: "user", text: "calendar" } },
      { seq: 3, item: { kind: "tool", id: "call_dead", name: "get_calendar", args: {}, status: "running" } },
    ]);
    const s = await idle(t, id);
    const tool = s.items.find((it) => it.kind === "tool");
    expect([tool.status, tool.interrupted]).toEqual(["error", true]);
    expect(shown(s.items).at(-1)).toMatch(/That didn't work: Interrupted/);
    // The model learned about the call.
    const call = net.aiBody.messages.find((m: { tool_calls?: { id: string }[] }) => m.tool_calls?.[0]?.id === "call_dead");
    expect(call.tool_calls[0].function.name).toBe("get_calendar");
  });

  it("go on with a turn after the worker restarted", async () => {
    const t = await setup({ leaseMs: 100, heartbeatMs: 20 });
    expect(await t.fire("POST", `${t.ai}/chats`, { text: "keep looking 5 times slowly", ...CONTEXT })).toBe(200);
    const id = (await t.call("GET", `${t.ai}/chats`)).data.chats[0].id;
    // The first worker goes away in the middle of the turn.
    for (let i = 0; i < 200 && !t.runner.active; i++) await new Promise((r) => setTimeout(r, 5));
    await t.stop();
    expect((await state(t, id)).chat.status).toBe("running");
    // A new one takes it over once its hold ran out.
    const next = new ChatRunner(t.env, 4, () => {});
    const ticking = setInterval(() => next.tick(), 5);
    try {
      const s = await idle(t, id);
      expect(shown(s.items).at(-1)).toBe("assistant: Done looking: 5 times.");
    } finally {
      clearInterval(ticking);
      await next.stop(1000);
    }
  }, 20_000);

  it("are their user's; viewers chat too", async () => {
    const t = await setup();
    const { id } = await start(t, "hello");
    const other = makeUser(t.db, { email: "other@test" });
    t.db.insert(familyMembers).values({ familyId: t.familyId, userId: other.id, role: "editor", joinedAt: NOW }).run();
    const as = t.as(createToken(t.db, { userId: other.id, kind: "api" }, NOW).token);
    expect((await as("GET", `${t.ai}/chats`)).data.chats).toEqual([]);
    expect((await as("GET", `${t.ai}/chats/${id}`)).status).toBe(404);
    expect((await as("POST", `${t.ai}/chats/${id}/messages`, { text: "hi" })).status).toBe(404);
    expect((await as("DELETE", `${t.ai}/chats/${id}`)).status).toBe(404);
    expect((await t.call("POST", `${t.ai}/chats`, { ...CONTEXT })).status).toBe(400);

    // A viewer's chat: the assistant reads, but changes nothing.
    const res = await t.view("POST", `${t.ai}/chats`, { text: "Add vacation from 2026-08-03 to 2026-08-07", ...CONTEXT });
    expect(res.status).toBe(200);
    const mine = (await t.view("GET", `${t.ai}/chats`)).data.chats;
    expect(mine).toHaveLength(1);
    expect(net.aiBody.tools.some((x: { function: { name: string } }) => x.function.name === "change_entries")).toBe(false);
    expect((await t.call("GET", `${t.f}/entries?year=2026`)).data).toEqual({});

    // Not a member: as if there were no such family.
    const stranger = makeUser(t.db, { email: "stranger@test" });
    const s = t.as(createToken(t.db, { userId: stranger.id, kind: "api" }, NOW).token);
    expect((await s("GET", `${t.ai}/chats`)).status).toBe(404);

    expect((await t.call("DELETE", `${t.ai}/chats/${id}`)).status).toBe(200);
    expect((await t.call("GET", `${t.ai}/chats/${id}`)).status).toBe(404);
  });

  it("need the AI to be set up", async () => {
    const t = assistantTest({ worker: false });
    current.push(t);
    expect((await t.call("POST", `${t.ai}/chats`, { text: "hi", ...CONTEXT })).status).toBe(400);
  });

  it("tell undone changes to the assistant with the next message", async () => {
    const t = await setup();
    const { id } = await start(t, "Add vacation from 2026-08-03 to 2026-08-07");
    const change = (await state(t, id)).items.find((it) => it.kind === "change");
    for (const step of change.undo) {
      expect((await t.call(step.method, `${t.f}${step.path}`, step.body)).status).toBe(200);
    }
    expect((await t.call("POST", `${t.ai}/chats/${id}/undone`, { id: change.id })).status).toBe(200);
    expect((await state(t, id)).items.find((it) => it.kind === "change").undone).toBe(true);
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "thanks", ...CONTEXT });
    expect(net.aiBody.messages.slice(-3)).toEqual([
      { role: "user", content: "(I undid this change: 5 days changed)" },
      { role: "assistant", content: "OK." },
      { role: "user", content: "thanks" },
    ]);
  });

  it("carry attached files and images", async () => {
    const t = await setup();
    const url = "data:image/png;base64,iVBORw0KGgo=";
    const res = await t.call("POST", `${t.ai}/chats`, {
      text: "what is this?",
      attachments: [
        { kind: "file", name: "list.csv", text: "a,b\n1,2" },
        { kind: "image", name: "shot.png", url },
      ],
      ...CONTEXT,
    });
    expect(res.status).toBe(200);
    const s = await state(t, res.data[0].data.id);
    expect(s.items[0].attachments).toEqual([
      { kind: "file", name: "list.csv" },
      { kind: "image", name: "shot.png", url },
    ]);
    expect(s.items.at(-1).text).toMatch(/I see 1 image/);
    expect(net.aiBody.messages[1].content[1].text).toBe("Attached file “list.csv”:\n```\na,b\n1,2\n```");
    const bad = await t.call("POST", `${t.ai}/chats`, { attachments: [{ kind: "image", name: "x", url: "javascript:alert(1)" }] });
    expect(bad.status).toBe(400);
  });

  it("import a chat kept elsewhere", async () => {
    const t = await setup();
    const updatedAt = Date.parse("2026-03-01T10:00:00Z");
    const res = await t.call("POST", `${t.ai}/chats/import`, {
      title: "Old chat",
      updatedAt,
      items: [
        { kind: "user", text: "hi" },
        { kind: "assistant", text: "Hello!" },
        {
          kind: "change",
          id: "c1",
          change: "entries",
          summary: "1 day changed",
          undo: [
            { method: "POST", path: "/entries", body: { ops: [] } },
            { method: "GET", path: "https://evil.test" },
          ],
        },
        { kind: "bogus" },
      ],
      history: [
        { role: "user", content: "hi" },
        { role: "assistant", content: "Hello!" },
      ],
    });
    expect(res.status, JSON.stringify(res.data)).toBe(201);
    const id = res.data.chat.id;
    expect(res.data.chat.updatedAt).toBe(new Date(updatedAt).toISOString());
    const s = await state(t, id);
    expect(shown(s.items)).toEqual(["user: hi", "assistant: Hello!", "change"]);
    expect(s.items[2].undo).toEqual([{ method: "POST", path: "/entries", body: { ops: [] } }]);
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "again", ...CONTEXT });
    expect(net.aiBody.messages.slice(1).map((m: { content: string }) => m.content)).toEqual(["hi", "Hello!", "again"]);
  });

  it("keep messages written while the assistant answers, which then go next", async () => {
    const t = await setup();
    expect(await t.fire("POST", `${t.ai}/chats`, { text: "take your time", ...CONTEXT })).toBe(200);
    const id = (await t.call("GET", `${t.ai}/chats`)).data.chats[0].id;
    // A follower from the start sees both turns, and only then the end.
    const following = t.call("GET", `${t.ai}/chats/${id}/events?since=0`);
    const first = await t.call("POST", `${t.ai}/chats/${id}/queue`, {
      text: "and then?",
      attachments: [{ kind: "file", name: "list.csv", text: "a,b" }],
      ...CONTEXT,
    });
    expect(first.status, JSON.stringify(first.data)).toBe(202);
    expect(first.data.chat.status).toBe("running");
    expect(first.data.chat.queued).toEqual([
      { id: first.data.id, text: "and then?", attachments: [{ kind: "file", name: "list.csv" }] },
    ]);
    const second = await t.call("POST", `${t.ai}/chats/${id}/queue`, { text: "last", ...CONTEXT, page: "finance" });
    expect(second.data.chat.queued.map((q: { text: string }) => q.text)).toEqual(["and then?", "last"]);
    const s = await idle(t, id);
    expect(shown(s.items)).toEqual([
      "user: take your time",
      "assistant: Sorry for the wait.",
      "user: and then?",
      "assistant: Mock reply: and then?\nAttached file “list.csv”:\n```\na,b\n```",
      "user: last",
      "assistant: Mock reply: last",
    ]);
    expect(s.items[2].attachments).toEqual([{ kind: "file", name: "list.csv" }]);
    expect(s.chat.queued).toEqual([]);
    expect(net.aiBody.messages.slice(1).map((m: { role: string }) => m.role)).toEqual(["user", "assistant", "user", "assistant", "user"]);
    // A message written on another page doesn't move the chat: it stays on its page.
    expect(s.chat.page).toBe("calendar");
    const ev = (await following).data as Event[];
    expect(ev.at(-1)!.event).toBe("end");
    expect(shown(replay(ev))).toEqual(shown(s.items));
  });

  it("take back a waiting message, and go on with the next after a stop", async () => {
    const t = await setup();
    expect(await t.fire("POST", `${t.ai}/chats`, { text: "take your time", ...CONTEXT })).toBe(200);
    const id = (await t.call("GET", `${t.ai}/chats`)).data.chats[0].id;
    const queue = (text: string) => t.call("POST", `${t.ai}/chats/${id}/queue`, { text, ...CONTEXT });
    const a = (await queue("never mind")).data.id;
    await queue("hello");
    const back = await t.call("POST", `${t.ai}/chats/${id}/unqueue`, { id: a });
    expect(back.status).toBe(200);
    expect(back.data.chat.queued.map((q: { text: string }) => q.text)).toEqual(["hello"]);
    // Taken back already: nothing changes.
    const again = await t.call("POST", `${t.ai}/chats/${id}/unqueue`, { id: a });
    expect(again.data.chat.queued.map((q: { text: string }) => q.text)).toEqual(["hello"]);
    // Only so many can wait.
    for (let i = 1; i < 10; i++) expect((await queue(`more ${i}`)).status).toBe(202);
    expect((await queue("too many")).status).toBe(409);
    for (const q of (await state(t, id)).chat.queued.slice(1)) {
      await t.call("POST", `${t.ai}/chats/${id}/unqueue`, { id: q.id });
    }
    // Stopping ends the running answer; the waiting message goes on.
    expect((await t.call("POST", `${t.ai}/chats/${id}/stop`)).status).toBe(200);
    const s = await idle(t, id);
    expect(shown(s.items)).toEqual(["user: take your time", "user: hello", "assistant: Mock reply: hello"]);
    expect(net.aiBody.messages.slice(1)).toEqual([
      { role: "user", content: "take your time" },
      { role: "assistant", content: "(stopped)" },
      { role: "user", content: "hello" },
    ]);
    // Another user's chat can't be queued to.
    const other = makeUser(t.db, { email: "other@test" });
    t.db.insert(familyMembers).values({ familyId: t.familyId, userId: other.id, role: "editor", joinedAt: NOW }).run();
    const as = t.as(createToken(t.db, { userId: other.id, kind: "api" }, NOW).token);
    expect((await as("POST", `${t.ai}/chats/${id}/queue`, { text: "x" })).status).toBe(404);
  });

  it("start a turn for a message queued to an idle chat, also if it was left waiting", async () => {
    const t = await setup();
    const { id } = await start(t, "hello");
    const res = await t.call("POST", `${t.ai}/chats/${id}/queue`, { text: "again", ...CONTEXT });
    expect(res.status).toBe(202);
    expect(res.data.chat.status).toBe("running");
    let s = await idle(t, id);
    expect(shown(s.items).slice(-2)).toEqual(["user: again", "assistant: Mock reply: again"]);
    // As if the worker that ended a turn died before the waiting message started: the next
    // tick starts it.
    await t.store.queueChatMessage(id, {
      id: "q1",
      item: { kind: "user", text: "left behind" },
      content: "left behind",
      context: CONTEXT,
    });
    s = await idle(t, id);
    expect(shown(s.items).slice(-2)).toEqual(["user: left behind", "assistant: Mock reply: left behind"]);
  });

  it("keep only the newest 100 chats per user", async () => {
    const t = await setup({}, {}, false);
    const old = new Date("2026-01-01T00:00:00Z").getTime();
    for (let i = 0; i < 100; i++) {
      await t.store.createChat({
        id: `old-${i}`,
        family_id: t.familyId,
        user_id: t.editor.id,
        title: `Old ${i}`,
        status: "idle",
        run_token: null,
        run_until: null,
        stop: false,
        retries: 0,
        context: {},
        activity: null,
        notes: [],
        usage: null,
        queue: [],
        rev: 0,
        created_at: new Date(old + i * 1000).toISOString(),
        updated_at: new Date(old + i * 1000).toISOString(),
      });
    }
    expect(await t.fire("POST", `${t.ai}/chats`, { text: "new", ...CONTEXT })).toBe(200);
    const list = (await t.call("GET", `${t.ai}/chats`)).data.chats;
    expect(list).toHaveLength(100);
    expect(list[0].title).toBe("new");
    expect(list.some((c: { id: string }) => c.id === "old-0")).toBe(false);
  });
});
