// family-planner's tests/ai.test.ts: the AI settings, the endpoint's models, one turn of the
// tool loop (runChat, as the worker runs it, with the mock AI), the tools, web search and
// pages, the context window, and sorting transactions into categories. family-planner ran
// turns through POST /ai/chat; Ohana has no such route (turns run in the worker), so these
// tests call runChat with the turn prepareTurn sets up.

import { afterEach, describe, expect, it } from "vitest";
import { parseAnswer } from "@/lib/assistant/categorize";
import { cleanContext, cleanHistory, runChat } from "@/lib/assistant/chat";
import { htmlToText, isPrivateAddress } from "@/lib/assistant/net";
import { prepareTurn } from "@/lib/assistant/routes";
import type { ChatRow } from "@/lib/assistant/store";
import { runTool } from "@/lib/assistant/tools";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import { similarKey } from "@/lib/finance/finance";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { AI, type AssistantTest, assistantTest, configure, type Event, fakeFetch, KEY, net } from "@/lib/test/assistant";
import type { AiEnv } from "@/lib/assistant/routes";

let current: AssistantTest[] = [];
afterEach(async () => {
  await Promise.all(current.map((t) => t.stop()));
  current = [];
});

/** A family without AI settings (no worker: these tests run turns themselves). */
function family(env: Partial<AiEnv> = {}) {
  const t = assistantTest({ env, worker: false });
  current.push(t);
  return t;
}

async function configured(env: Partial<AiEnv> = {}, settings: Record<string, unknown> = {}) {
  const t = family(env);
  await configure(t, settings);
  return t;
}

/** The events but how full the context is (sent before and after every model call). */
const names = (ev: Event[]) => ev.map((e) => e.event).filter((n) => n !== "usage");

/** What the turn adds to the history: the messages of every step. */
const addedOf = (ev: Event[]) => ev.filter((e) => e.event === "messages").flatMap((e) => e.data.messages);
const textOf = (ev: Event[]) =>
  ev
    .filter((e) => e.event === "text")
    .map((e) => e.data.delta)
    .join("");

/** One turn of the tool loop, as the worker runs it for the editor (or `user`). */
async function chat(
  t: AssistantTest,
  text: string,
  extra: {
    messages?: unknown[];
    continue?: boolean;
    page?: string;
    handOffMs?: number;
    deadlineMs?: number;
    user?: string;
  } = {},
) {
  const family = (await new DrizzleCalendarStore(t.db).getFamily(t.familyId))!;
  const context = cleanContext({ today: "2026-03-10", year: 2026, lang: "en", page: extra.page ?? "calendar" });
  const history = cleanHistory(extra.messages ?? [{ role: "user", content: text }], extra.continue === true);
  const chat = { user_id: extra.user ?? t.editor.id } as ChatRow;
  const turn = await prepareTurn(t.env, chat, family, context);
  const ev: Event[] = [];
  await runChat({
    ...turn,
    history,
    emit: (event, data) => ev.push({ event, data }),
    handOffMs: extra.handOffMs ?? Infinity,
    deadlineMs: extra.deadlineMs ?? Infinity,
  });
  return ev;
}

async function entries(t: AssistantTest) {
  return (await t.call("GET", `${t.f}/entries?year=2026`)).data;
}

describe("AI settings", () => {
  it("stores the AI settings with the keys encrypted and never returns them", async () => {
    const t = family();
    const empty = await t.call("GET", `${t.ai}/settings`);
    expect([empty.data.configured, empty.data.hasKey, empty.data.serverReady]).toEqual([false, false, true]);

    const res = await t.call("PUT", `${t.ai}/settings`, {
      baseUrl: AI + "/",
      apiKey: KEY,
      model: "mock-large",
      searchProvider: "tavily",
      searchKey: "tvly-abcdef9876",
      allowWrites: false,
    });
    expect(res.data).toEqual({
      configured: true,
      canEdit: true,
      baseUrl: AI,
      model: "mock-large",
      hasKey: true,
      keyHint: "abcd",
      searchProvider: "tavily",
      hasSearchKey: true,
      searchKeyHint: "9876",
      allowWrites: false,
      contextWindow: 0,
      imageModel: "",
      serverReady: true,
    });
    const row = (await t.store.getAiSettings(t.familyId))!;
    expect(row.api_key_enc.startsWith("v1:") && !row.api_key_enc.includes(KEY)).toBe(true);
    // Only the fields given change; "" removes a key.
    const cleared = await t.call("PUT", `${t.ai}/settings`, { apiKey: "" });
    expect([cleared.data.hasKey, cleared.data.model]).toEqual([false, "mock-large"]);

    // Viewers see whether it is set up, not the setup; they can't change it.
    const seen = await t.view("GET", `${t.ai}/settings`);
    expect(seen.data).toEqual({ configured: true, canEdit: false, model: "mock-large", allowWrites: false, serverReady: true });
    expect((await t.view("PUT", `${t.ai}/settings`, { model: "x" })).status).toBe(403);
    expect((await t.call("PUT", `${t.ai}/settings`, { searchProvider: "bing" })).status).toBe(400);
    expect((await t.call("PUT", `${t.ai}/settings`, { apiKey: "has space" })).status).toBe(400);
    // The model's context window: a number of tokens, or 0 to find it out.
    const window = await t.call("PUT", `${t.ai}/settings`, { contextWindow: 32000 });
    expect(window.data.contextWindow).toBe(32000);
    for (const contextWindow of [-1, 500, 1.5, "32000", 20_000_000]) {
      expect((await t.call("PUT", `${t.ai}/settings`, { contextWindow })).status, String(contextWindow)).toBe(400);
    }
  });

  it("refuses AI endpoints and pages on private networks", async () => {
    for (const host of [
      "127.0.0.1",
      "10.1.2.3",
      "192.168.0.10",
      "169.254.169.254",
      "::1",
      "fd00::1",
      "localhost",
      "intranet",
      "2130706433",
      "printer.local",
    ]) {
      expect(isPrivateAddress(host), host).toBe(true);
    }
    for (const host of ["93.184.216.34", "api.openai.com", "2606:4700::1111"]) {
      expect(isPrivateAddress(host), host).toBe(false);
    }
    const t = family();
    for (const baseUrl of ["http://localhost:11434/v1", "http://10.0.0.5/v1", "ftp://x.test/v1"]) {
      expect((await t.call("PUT", `${t.ai}/settings`, { baseUrl })).status, baseUrl).toBe(400);
    }
    // A public name that resolves to a private address.
    const sneaky = family({ modelNet: { fetch, resolve: () => Promise.resolve(["10.0.0.7"]) } });
    expect((await sneaky.call("PUT", `${sneaky.ai}/settings`, { baseUrl: "https://evil.test/v1" })).status).toBe(400);
    // A model on the home network, when the server allows it (AI_ALLOW_PRIVATE_ENDPOINT).
    const home = family({ modelNet: { fetch, allowPrivate: true } });
    expect((await home.call("PUT", `${home.ai}/settings`, { baseUrl: "http://localhost:11434/v1" })).status).toBe(200);
  });

  it("lists the endpoint's models and tests the connection", async () => {
    const t = family();
    // The form can ask before anything is saved.
    const list = await t.call("POST", `${t.ai}/models`, { baseUrl: AI, apiKey: KEY });
    expect(list.data.models).toEqual(["mock-large", "mock-small", "mock-tiny"]);
    expect((await t.call("POST", `${t.ai}/test`)).status).toBe(400); // nothing saved yet
    await t.call("PUT", `${t.ai}/settings`, { baseUrl: AI, apiKey: KEY, model: "mock-small" });
    const test = await t.call("POST", `${t.ai}/test`);
    expect([test.data.ok, test.data.model]).toEqual([true, "mock-small"]);
    expect(test.data.reply).toMatch(/Mock reply/);
    expect((await t.view("POST", `${t.ai}/test`)).status).toBe(403);
    expect((await t.view("POST", `${t.ai}/models`, {})).status).toBe(403);
  });
});

describe("a turn of the assistant", () => {
  it("changes the calendar, and the change can be undone", async () => {
    const t = await configured();
    const ev = await chat(t, "Add vacation from 2026-08-03 to 2026-08-07");
    expect(names(ev).filter((n) => n !== "text")).toEqual(["tool", "tool_result", "change", "messages", "messages", "done"]);
    const tool = ev.find((e) => e.event === "tool")!.data;
    expect(tool.name).toBe("change_entries");
    const change = ev.find((e) => e.event === "change")!.data;
    expect([change.kind, change.summary]).toEqual(["entries", "5 days changed"]);
    const days = await entries(t);
    expect(Object.keys(days)).toHaveLength(5);
    expect(days["2026-08-03"]).toEqual(["vacation"]);
    expect(textOf(ev)).toMatch(/Done: 5 days changed/);
    // How full the context is: the window from the endpoint's model list, the tokens it reported.
    expect(net.aiBody.stream_options.include_usage).toBe(true);
    const usage = ev.filter((e) => e.event === "usage").map((e) => e.data);
    expect(usage.length).toBeGreaterThanOrEqual(4);
    expect(usage.every((u) => u.max === 64000 && u.used > 1000 && u.used < 64000)).toBe(true);

    // The history for the next turn: the call, its result and the answer.
    const added = addedOf(ev);
    expect(added.map((m) => m.role)).toEqual(["assistant", "tool", "assistant"]);
    expect(added[1].tool_call_id).toBe(added[0].tool_calls[0].id);

    // Undo through the family's own API.
    for (const step of change.undo) {
      expect((await t.call(step.method, `${t.f}${step.path}`, step.body)).status).toBe(200);
    }
    expect(await entries(t)).toEqual({});

    // The next turn sends the whole history back.
    const next = await chat(t, "", {
      messages: [{ role: "user", content: "Add vacation from 2026-08-03 to 2026-08-07" }, ...added, { role: "user", content: "thanks" }],
    });
    expect(textOf(next)).toMatch(/Mock reply: thanks/);
  });

  it("is told which page the chat belongs to and keeps to it", async () => {
    const t = await configured();
    await chat(t, "hello", { page: "finance" });
    const system = net.aiBody.messages[0].content;
    expect(system).toMatch(/## This chat's page\nThis chat belongs to the finance page, which shows the finances/);
    expect(system).toMatch(/don't suggest calendar entries/);
    await chat(t, "hello", { page: "vacation" }); // family-planner's name of the calendar page
    expect(net.aiBody.messages[0].content).toMatch(/belongs to the calendar page, which shows the vacation calendar/);
  });

  it("needs the user's confirmation for big changes", async () => {
    const t = await configured();
    const ev = await chat(t, "vacation 2026-01-01 to 2026-03-31");
    const result = ev.find((e) => e.event === "tool_result")!.data;
    expect(result.ok).toBe(false);
    expect(result.summary).toMatch(/Ask the user to confirm/);
    expect(ev.some((e) => e.event === "change")).toBe(false);
    expect(await entries(t)).toEqual({});
  });

  it("asks a question and goes on with the answer", async () => {
    const t = await configured({}, { allowWrites: false });
    const user = { role: "user", content: "ask several" };
    const ev = await chat(t, user.content);
    // The model is told to ask rather than guess.
    expect(net.aiBody.messages[0].content).toMatch(/## Ask instead of guessing/);
    // The question ends the turn, without the call's result: that is the user's answer.
    expect(names(ev).filter((n) => n !== "text")).toEqual(["messages", "question", "done"]);
    const added = addedOf(ev);
    expect(added).toHaveLength(1);
    const call = added[0].tool_calls[0];
    expect(call.function.name).toBe("ask_user");
    expect(ev.find((e) => e.event === "question")!.data).toEqual({
      id: call.id,
      question: "Where would you like to go?",
      options: ["Beach", "Mountains", "City"],
      multiple: true,
    });

    // The answer is the call's result, and the turn goes on.
    const answer = { selected: ["Beach", "City"], ownAnswer: "A lake" };
    const history = [user, ...added, { role: "tool", tool_call_id: call.id, content: JSON.stringify(answer) }];
    const next = await chat(t, "", { messages: history, continue: true });
    expect(next.some((e) => e.event === "done")).toBe(true);
    expect(textOf(next)).toBe("You answered: Beach, City, A lake.");
  });

  it("checks questions: a text and 2 to 8 different options", async () => {
    const ask = (args: unknown) => runTool("ask_user", JSON.stringify(args), {} as never, new Set(["ask_user"]));
    const ok = await ask({ question: " Which one? ", options: ["A", " B", "A", ""] });
    expect(ok.ok).toBe(true);
    expect(ok.question).toEqual({ question: "Which one?", options: ["A", "B"], multiple: false });
    for (const bad of [
      { question: "", options: ["A", "B"] },
      { question: "Which?", options: ["A", "A"] },
      { question: "Which?", options: "A, B" },
      { question: "Which?", options: ["1", "2", "3", "4", "5", "6", "7", "8", "9"] },
      { question: "Which?", options: ["A", "B".repeat(151)] },
    ]) {
      const res = await ask(bad);
      expect(res.ok, JSON.stringify(bad)).toBe(false);
      expect(res.question).toBeUndefined();
    }
  });

  it("only gets the tools that read with changes switched off, and for viewers", async () => {
    const t = await configured({}, { allowWrites: false });
    const ev = await chat(t, "Add vacation from 2026-08-03 to 2026-08-07");
    expect(ev.some((e) => e.event === "tool")).toBe(false);
    expect(await entries(t)).toEqual({});
    expect(net.aiBody.messages[0].content).toMatch(/switched off in the settings/);
    // Reading still works.
    const read = await chat(t, "what's in my calendar?");
    expect(read.find((e) => e.event === "tool")!.data.name).toBe("get_calendar");

    // A viewer's turn reads only, whatever the settings say.
    const v = await configured();
    const asViewer = await chat(v, "Add vacation from 2026-08-03 to 2026-08-07", { user: v.viewer.id });
    expect(asViewer.some((e) => e.event === "tool")).toBe(false);
    expect(net.aiBody.tools.some((x: { function: { name: string } }) => x.function.name === "change_entries")).toBe(false);
    expect(net.aiBody.messages[0].content).toMatch(/can only view this family/);
    expect(await entries(v)).toEqual({});
  });

  it("searches the web and reads pages, but not private ones", async () => {
    const t = await configured({}, { searchProvider: "tavily", searchKey: "tvly-key" });
    const search = await chat(t, "search school holidays Bavaria 2027");
    expect(search.find((e) => e.event === "tool")!.data.name).toBe("web_search");
    expect(search.find((e) => e.event === "tool_result")!.data.ok).toBe(true);

    const page = await chat(t, "read https://pages.test/ferien please");
    const tool = JSON.parse(addedOf(page)[1].content);
    expect(tool.title).toBe("School holidays 2027");
    expect(tool.text.includes("Summer: Aug 2 – Sep 13") && !tool.text.includes("evil")).toBe(true);

    // The whole tool result goes into the history (the chat shortens what it shows itself).
    const long = await chat(t, "read https://pages.test/long please");
    const longTool = addedOf(long)[1].content;
    expect(longTool.length > 7000 && !longTool.includes("…(truncated)")).toBe(true);

    for (const url of ["http://169.254.169.254/latest/meta-data", "https://redirect.test/"]) {
      const ev = await chat(t, `read ${url}`);
      const res = ev.find((e) => e.event === "tool_result")!.data;
      expect(res.ok, url).toBe(false);
      expect(res.summary).toMatch(/[Pp]rivate/);
    }
    expect(net.requests.some((r) => r.includes("169.254"))).toBe(false);
  });

  it("never reads private pages, also when the model may be on the home network", async () => {
    const t = await configured({ modelNet: { fetch: fakeFetch, resolve: () => Promise.resolve(["93.184.216.34"]), allowPrivate: true } });
    const ev = await chat(t, "read http://169.254.169.254/latest/meta-data");
    const res = ev.find((e) => e.event === "tool_result")!.data;
    expect(res.ok).toBe(false);
    expect(res.summary).toMatch(/[Pp]rivate/);
  });

  it("asks an endpoint that doesn't know stream_options without it", async () => {
    const t = await configured({}, { baseUrl: AI + "/strict" });
    const before = net.requests.length;
    const ev = await chat(t, "hello");
    expect(textOf(ev)).toMatch(/hello/);
    expect(net.aiBody.stream_options).toBeUndefined();
    // Refused once, then asked without it (also from now on).
    const completions = () => net.requests.slice(before).filter((r) => r.endsWith("/chat/completions")).length;
    expect(completions()).toBe(2);
    await chat(t, "again");
    expect(completions()).toBe(3);
    // Without the endpoint's numbers, the context in use is estimated.
    const usage = ev.filter((e) => e.event === "usage").map((e) => e.data);
    expect(usage.length > 0 && usage.every((u) => u.used > 1000 && u.max === 64000)).toBe(true);
  });

  it("runs on as long as the model works, without a limit of steps", async () => {
    const t = await configured();
    const ev = await chat(t, "keep looking 60 times");
    expect(ev.filter((e) => e.event === "tool")).toHaveLength(60);
    expect(net.aiBody.tool_choice).toBe("auto");
    expect(addedOf(ev).at(-1)).toEqual({ role: "assistant", content: "Done looking: 60 times." });
    expect(ev.some((e) => e.event === "done")).toBe(true);
    expect(ev.some((e) => e.event === "compacted")).toBe(false); // it all fits
  });

  it("condenses a conversation too long for the context instead of cutting it off", async () => {
    const t = await configured({}, { contextWindow: 16000 });
    const user = { role: "user", content: "keep looking 40 times" };
    const ev = await chat(t, user.content);
    // It looked 40 times in all: the summary keeps count of the looks it condensed.
    expect(ev.filter((e) => e.event === "tool")).toHaveLength(40);
    expect(addedOf(ev).at(-1)).toEqual({ role: "assistant", content: "Done looking: 40 times." });
    const compacted = ev.filter((e) => e.event === "compacted").map((e) => e.data);
    expect(compacted.length).toBeGreaterThanOrEqual(1);
    expect(compacted[0].summary).toMatch(/^Looked \d+ times/);
    // The user's request stays word for word with the summary.
    expect(compacted[0].request).toBe(user.content);
    expect(ev.findIndex((e) => e.event === "compacting")).toBeLessThan(ev.findIndex((e) => e.event === "compacted"));
    // The model got the summary first, then the newest messages (from a call, not a result).
    const [, summary, next] = net.aiBody.messages;
    expect(summary.role).toBe("user");
    expect(summary.content).toMatch(/condensed[\s\S]*Looked \d+ times[\s\S]*keep looking 40 times$/);
    expect(next.role).toBe("assistant");
    // The context never got full.
    const usage = ev.filter((e) => e.event === "usage").map((e) => e.data);
    expect(usage.every((u) => u.max === 16000 && u.used < 16000), JSON.stringify(usage)).toBe(true);
  });

  it("condenses the conversation when the endpoint says the context is full", async () => {
    // The model list doesn't tell this model's window (12,000): only its error does.
    const t = await configured({}, { model: "mock-tiny" });
    const ev = await chat(t, "keep looking 50 times");
    expect(addedOf(ev).at(-1)).toEqual({ role: "assistant", content: "Done looking: 50 times." });
    expect(ev.some((e) => e.event === "compacted")).toBe(true);
    expect(ev.some((e) => e.event === "continue")).toBe(false);
    const usage = ev.filter((e) => e.event === "usage").map((e) => e.data);
    expect(usage[0].max).toBe(128000);
    expect(usage.at(-1).max).toBe(12000);
  });

  it("hands a turn on when its time is up (family-planner's limit; the worker passes none)", async () => {
    const t = await configured();
    const user = { role: "user", content: "keep looking" };
    let ev = await chat(t, "keep looking", { handOffMs: 0 });
    expect(names(ev)).toEqual(["tool", "tool_result", "messages", "continue"]);
    const history: unknown[] = [user, ...addedOf(ev)];
    let rounds = 1;
    for (;;) {
      ev = await chat(t, "", { messages: history, continue: true, handOffMs: 0 });
      history.push(...addedOf(ev));
      rounds++;
      if (!ev.some((e) => e.event === "continue")) break;
      expect(ev.filter((e) => e.event === "tool")).toHaveLength(1);
    }
    // It looked 30 times, one step per round, then answered.
    expect(rounds).toBe(31);
    expect(history.at(-1)).toEqual({ role: "assistant", content: "Done looking: 30 times." });

    // Continuing needs tool results last; a new turn needs the user's message last.
    const turn = history.slice(0, -1);
    expect(() => cleanHistory([user], true)).toThrow();
    expect(() => cleanHistory(turn.slice(0, 2), true)).toThrow();
    expect(() => cleanHistory(turn)).toThrow();
    expect(() => cleanHistory([])).toThrow();
    expect(() => cleanHistory([{ role: "system", content: "x" }])).toThrow();
  });

  it("asks a model that ends without a word again for its answer", async () => {
    const t = await configured();
    let ev = await chat(t, "say nothing");
    expect(net.aiBody.tool_choice).toBe("none");
    expect(net.aiBody.messages[0].content.includes("## Answer now")).toBe(true);
    expect(textOf(ev)).toBe("Here is the calendar.");
    let added = addedOf(ev);
    expect(added.map((m) => m.role)).toEqual(["assistant", "tool", "assistant"]);
    expect(added.at(-1)).toEqual({ role: "assistant", content: "Here is the calendar." });

    // Still nothing after five tries: the chat says so instead of ending blank.
    const before = net.requests.length;
    ev = await chat(t, "stay silent");
    expect(net.requests.length - before).toBe(6);
    expect(ev.find((e) => e.event === "text")?.data.delta).toBe("(The model gave no answer.)");
    added = addedOf(ev);
    expect(added).toEqual([{ role: "assistant", content: "(The model gave no answer.)" }]);
    expect(ev.some((e) => e.event === "done")).toBe(true);
  });

  it("hands a failed or too slow model call back to be tried again", async () => {
    // Too slow: cut off at the deadline.
    let t = await configured();
    let ev = (await chat(t, "take your time", { deadlineMs: 50 })).filter((e) => e.event !== "usage");
    expect(names(ev)).toEqual(["continue"]);
    expect(ev[0].data.retry).toBe(true);
    expect(ev[0].data.message).toMatch(/took too long/);

    // Failed after a step: that step is kept, and the turn goes on from its tool results.
    t = await configured();
    ev = (await chat(t, "keep looking, then fail")).filter((e) => e.event !== "usage");
    expect(names(ev)).toEqual(["tool", "tool_result", "messages", "continue"]);
    expect(ev[3].data.retry).toBe(true);
    expect(ev[3].data.message).toMatch(/refused the request: 503/);
    expect(addedOf(ev).at(-1).role).toBe("tool");
  });

  it("reads the finances", async () => {
    const t = await configured();
    await t.call("POST", `${t.f}/finance/transactions`, {
      ops: [
        { date: "2026-02-01", amountCents: 100000 },
        { date: "2026-02-02", amountCents: -2500 },
      ],
    });
    const ev = await chat(t, "how much did we spend?");
    expect(ev.find((e) => e.event === "tool")!.data.name).toBe("finance_summary");
    expect(textOf(ev)).toMatch(/Income 1000, expenses 25/);
  });

  it("calculates and analyzes the finances, also read-only", async () => {
    const t = await configured({}, { allowWrites: false });
    await t.call("POST", `${t.f}/finance/transactions`, {
      ops: [
        { date: "2026-02-01", amountCents: -2500, categoryId: "groceries" },
        { date: "2026-02-03", amountCents: -1500, categoryId: "groceries" },
      ],
    });
    const calc = await chat(t, "calculate round(1199.1 * 12 * 1.19, 2)");
    expect(calc.find((e) => e.event === "tool")!.data.name).toBe("calculate");
    expect(textOf(calc)).toMatch(/= 17123\.15/);

    const analyze = await chat(t, "analyze category");
    expect(analyze.find((e) => e.event === "tool")!.data.args.groupBy).toEqual(["category"]);
    expect(textOf(analyze)).toMatch(/1 groups, 40 spent/);
  });

  it("adds categories, with undo, and deletes them only when confirmed", async () => {
    const t = await configured();
    const ev = await chat(t, "add category Pets");
    expect(ev.find((e) => e.event === "tool")!.data.name).toBe("manage_categories");
    const change = ev.find((e) => e.event === "change")!.data;
    expect([change.kind, change.summary]).toEqual(["categories", "Added the category “Pets”"]);
    const cats = async () => (await t.call("GET", `${t.f}/finance`)).data.categories as { id: string; name: string; kind: string; icon: string }[];
    const pets = (await cats()).find((c) => c.name === "Pets")!;
    expect([pets.id, pets.kind, pets.icon]).toEqual(["pets", "expense", "🐾"]);

    for (const step of change.undo) {
      expect((await t.call(step.method, `${t.f}${step.path}`, step.body)).status).toBe(200);
    }
    expect((await cats()).some((c) => c.name === "Pets")).toBe(false);

    // Deleting needs the user's OK.
    await chat(t, "add category Pets");
    const del = await chat(t, "delete category Pets");
    const result = del.find((e) => e.event === "tool_result")!.data;
    expect(result.ok).toBe(false);
    expect(result.summary).toMatch(/Ask the user to confirm/);
    expect((await cats()).some((c) => c.name === "Pets")).toBe(true);

    // Read-only chats can't add any.
    const ro = await configured({}, { allowWrites: false });
    expect((await chat(ro, "add category Pets")).some((e) => e.event === "tool")).toBe(false);
  });

  it("sets the statistic average, with undo", async () => {
    const t = await configured();
    const ctx = {
      lang: "en",
      calendar: new DrizzleCalendarStore(t.db),
      finance: new DrizzleFinanceStore(t.db),
      db: t.db,
      familyId: t.familyId,
    } as never;
    const allowed = new Set(["set_statistic_average"]);
    const set = (args: unknown) => runTool("set_statistic_average", JSON.stringify(args), ctx, allowed);
    const benchmark = async () => (await t.call("GET", `${t.f}/finance`)).data.benchmark;
    const undo = async (steps: { method: string; path: string; body?: unknown }[]) => {
      for (const step of steps) {
        const res = await t.call(step.method, `${t.f}${step.path}`, step.body);
        expect(res.status, JSON.stringify(res.data)).toBe(200);
      }
    };

    const first = await set({
      label: "Destatis 2024",
      expense: { lowCents: 300000, highCents: 450000 },
      categories: [{ category: "Groceries", lowCents: 60000, highCents: 80000 }],
    });
    expect(first.ok, JSON.stringify(first.result)).toBe(true);
    expect([first.change!.kind, first.change!.summary]).toEqual(["benchmark", "Set the statistic average"]);
    expect(await benchmark()).toEqual({
      label: "Destatis 2024",
      income: null,
      expense: { lowCents: 300000, highCents: 450000 },
      categories: [{ categoryId: "groceries", lowCents: 60000, highCents: 80000 }],
    });

    const second = await set({ income: { lowCents: 500000, highCents: 500000 } });
    expect((await benchmark()).income).toEqual({ lowCents: 500000, highCents: 500000 });
    await undo(second.change!.undo);
    expect((await benchmark()).expense).toEqual({ lowCents: 300000, highCents: 450000 });

    const cleared = await set({ clear: true });
    expect(cleared.change!.summary).toBe("Removed the statistic average");
    expect(await benchmark()).toBeNull();
    await undo(cleared.change!.undo);
    expect((await benchmark()).label).toBe("Destatis 2024");
    await undo(first.change!.undo);
    expect(await benchmark()).toBeNull();

    expect((await set({ categories: [{ category: "Nope", lowCents: 1 }] })).ok).toBe(false);
    expect((await set({ expense: { lowCents: -5 } })).ok).toBe(false);
    expect((await set({ expense: { lowCents: 9, highCents: 3 } })).ok).toBe(false);
  });

  it("passes on attached images, the newest 8 of a chat", async () => {
    const t = await configured();
    // A 1×1 PNG.
    const png =
      "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk" +
      "+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
    const image = { type: "image_url", image_url: { url: png, detail: "low" } };
    const ev = await chat(t, "", { messages: [{ role: "user", content: [{ type: "text", text: "what is this?" }, image] }] });
    expect(textOf(ev)).toMatch(/I see 1 image\. Mock reply: what is this\?/);
    // Only url is passed on.
    expect(net.aiBody.messages[1].content[1]).toEqual({ type: "image_url", image_url: { url: png } });

    const bad = [
      [{ role: "user", content: [{ type: "image_url", image_url: { url: "https://x.test/a.png" } }] }],
      [{ role: "user", content: [{ type: "image_url", image_url: { url: "data:image/svg+xml;base64,AA==" } }] }],
      [{ role: "user", content: [{ type: "audio", audio: "x" }] }],
      [{ role: "user", content: [] }],
      [{ role: "user", content: [{ type: "text", text: 5 }] }],
      [{ role: "user", content: [{ type: "text", text: "x".repeat(60_001) }] }],
      [{ role: "user", content: Array(5).fill(image) }],
      [
        { role: "user", content: "hi" },
        { role: "assistant", content: [image] },
        { role: "user", content: "and?" },
      ],
    ];
    for (const messages of bad) expect(() => cleanHistory(messages), JSON.stringify(messages).slice(0, 120)).toThrow();

    // Of 10 images in the history only the newest 8 reach the model.
    const messages = [
      { role: "user", content: [image, image, { type: "text", text: "first" }] },
      { role: "assistant", content: "ok" },
      { role: "user", content: [image, image, image, image] },
      { role: "assistant", content: "ok" },
      { role: "user", content: [{ type: "text", text: "last" }, image, image, image, image] },
    ];
    expect(textOf(await chat(t, "", { messages }))).toMatch(/I see 4 images\. Mock reply: last/);
    const sent = net.aiBody.messages.flatMap((m: { content: unknown }) => (Array.isArray(m.content) ? m.content : []));
    expect(sent.filter((p: { type: string }) => p.type === "image_url")).toHaveLength(8);
    expect(net.aiBody.messages[1].content.slice(0, 2)).toEqual([
      { type: "text", text: "(an earlier image, no longer sent)" },
      { type: "text", text: "(an earlier image, no longer sent)" },
    ]);
  });
});

describe("categorize", () => {
  /** Adds transactions; returns their ids in order. */
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

  it("sorts uncategorized transactions into fitting categories, with undo", async () => {
    const t = await configured();
    const ids = await addTransactions(t, [
      { date: "2026-02-01", amountCents: -4520, payee: "Supermarket", description: "groceries" },
      { date: "2026-02-02", amountCents: -1200, payee: "City", description: "Mobility pass" },
      // Income can't go to an expense category, whatever the model says.
      { date: "2026-02-03", amountCents: 900, payee: "Groceries refund" },
      { date: "2026-02-04", amountCents: -999, payee: "Something odd" },
      // Already sorted: stays as it is, and is shown to the model as an example.
      { date: "2026-01-15", amountCents: -5000, payee: "Pharmacy", categoryId: "health" },
    ]);
    const res = await t.call("POST", `${t.ai}/categorize`, { from: "2026-02-01", to: "2026-02-28" });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    expect([res.data.changed, res.data.considered, res.data.remaining]).toEqual([2, 4, 0]);
    expect(await categoryOf(t, ids)).toEqual(["groceries", "mobility", null, null, "health"]);
    expect(net.aiBody.temperature).toBe(0);
    expect(net.aiBody.messages[0].content).toMatch(/Pharmacy -> health/);
    expect(net.aiBody.messages[1].content).toMatch(/^1 \| 2026-02-04 \| -9\.99 \| Something odd \| $/m);

    const undo = await t.call("POST", `${t.f}/finance/transactions`, { ops: res.data.inverse });
    expect(undo.status).toBe(200);
    expect(await categoryOf(t, ids)).toEqual([null, null, null, null, "health"]);
  });

  it("categorizes given transactions, or a range page by page", async () => {
    const t = await configured();
    const ids = await addTransactions(
      t,
      Array.from({ length: 205 }, (_, i) => ({
        date: "2026-03-01",
        amountCents: -100 - i,
        payee: i % 2 ? "Unknown shop" : "Leisure park",
      })),
    );
    const one = await t.call("POST", `${t.ai}/categorize`, { ids: ids.slice(0, 2) });
    expect([one.data.changed, one.data.considered, one.data.remaining]).toEqual([1, 2, 0]);

    // 204 left open: 200 now, the rest on the next call (skipping the ones left uncategorized).
    const first = await t.call("POST", `${t.ai}/categorize`, {});
    expect([first.data.considered, first.data.remaining]).toEqual([200, 4]);
    const left = first.data.considered - first.data.changed;
    const next = await t.call("POST", `${t.ai}/categorize`, { skip: left });
    expect([next.data.considered, next.data.remaining]).toEqual([4, 0]);
    const cats = await categoryOf(t, ids);
    expect(cats.filter((c) => c === "leisure")).toHaveLength(103);
    expect(cats.filter((c) => c === null)).toHaveLength(102);
  });

  it("sorts like similar transactions without AI", async () => {
    const t = family(); // no AI settings
    const ids = await addTransactions(t, [
      { date: "2026-01-02", amountCents: -3000, payee: "REWE Markt 1234", categoryId: "groceries" },
      { date: "2026-01-09", amountCents: -2000, payee: "Rewe Markt 99", categoryId: "groceries" },
      { date: "2026-01-10", amountCents: -900, payee: "Kiosk", categoryId: "leisure" },
      { date: "2026-01-11", amountCents: -900, payee: "Kiosk", categoryId: "shopping" },
      { date: "2026-02-01", amountCents: -4520, payee: "REWE MARKT 5678" },
      // The family sorted the kiosk both ways: no clear answer.
      { date: "2026-02-02", amountCents: -800, payee: "Kiosk" },
      // Money back from the supermarket doesn't go into an expense category.
      { date: "2026-02-03", amountCents: 500, payee: "Rewe Markt 1" },
    ]);
    net.requests.length = 0;
    const res = await t.call("POST", `${t.ai}/categorize`, { from: "2026-02-01" });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    expect([res.data.changed, res.data.matched, res.data.ai]).toEqual([1, 1, false]);
    expect(res.data.assignments[0].source).toBe("similar");
    expect((await categoryOf(t, ids)).slice(4)).toEqual(["groceries", null, null]);
    expect(net.requests).toHaveLength(0);
    expect(similarKey({ payee: "", description: "SEPA 4711 Stadtwerke München GmbH" })).toBe("sepa stadtwerke münchen");
  });

  it("looks up unknown payees on the web when search is set up", async () => {
    const t = await configured({}, { searchProvider: "tavily", searchKey: "tvly-key" });
    const ids = await addTransactions(t, [{ date: "2026-02-01", amountCents: -2400, payee: "Zorbex" }]);
    net.requests.length = 0;
    const res = await t.call("POST", `${t.ai}/categorize`, {});
    expect([res.data.changed, res.data.matched]).toEqual([1, 0]);
    expect(await categoryOf(t, ids)).toEqual(["leisure"]);
    expect(net.requests.some((r) => r.startsWith("https://api.tavily.com"))).toBe(true);
    // The model got the search results back, and could have searched more.
    expect(net.aiBody.tool_choice).toBe("auto");
    expect(net.aiBody.messages[0].content).toMatch(/web_search/);
    expect(net.aiBody.messages.at(-1).role).toBe("tool");
  });

  it("needs an editor and valid input", async () => {
    const t = family();
    expect((await t.view("POST", `${t.ai}/categorize`, {})).status).toBe(403);
    expect((await t.call("POST", `${t.ai}/categorize`, { ids: ["x"] })).status).toBe(400);
    expect((await t.call("POST", `${t.ai}/categorize`, { from: "March" })).status).toBe(400);
    expect((await t.call("POST", `${t.ai}/categorize`, { skip: -1 })).status).toBe(400);
    // Nothing to do: no request to the model.
    net.requests.length = 0;
    const none = await t.call("POST", `${t.ai}/categorize`, {});
    expect([none.status, none.data.considered, net.requests.length]).toEqual([200, 0, 0]);
  });

  it("reads the model's answer even when it is wrapped", () => {
    expect(parseAnswer('Sure!\n```json\n{"1": "groceries", "2": null}\n```')).toEqual({ "1": "groceries", "2": null });
    expect(parseAnswer("no idea")).toEqual({});
    expect(parseAnswer("[1, 2]")).toEqual({});
  });
});

describe("helpers", () => {
  it("turns HTML into readable text", () => {
    const { title, text } = htmlToText(
      "<title>A &amp; B</title><style>p{}</style><ul><li>One</li><li>Two&nbsp;&#x2603;</li></ul>",
    );
    expect(title).toBe("A & B");
    expect(text).toBe("- One\n- Two ☃");
  });

  it("serves the instructions for AI agents", async () => {
    const t = family();
    const res = await t.call("GET", `${t.f}/agent`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toMatch(/text\/markdown/);
    expect(res.data).toMatch(/instructions for AI agents/);
    expect(res.data).toMatch(/full edit access/);
    expect(res.data).toContain(`http://ohana.test/api/v1/families/${t.familyId}/entries`);
    const seen = await t.view("GET", `${t.f}/agent`);
    expect(seen.data).toMatch(/can only \*\*view\*\*/);
  });
});
