// The assistant's suggestions (lib/assistant/tools/suggestions.ts): suggest_items offers the
// events, tasks and deadlines of a letter the user shared (e.g. scanned in the app) and waits
// for the user to pick the ones to add in the app (POST …/suggestions), like a Reminders edit.

import { afterEach, describe, expect, it } from "vitest";
import type { NetOptions } from "@/lib/assistant/net";
import { runTool, type ToolContext, TOOLS, toolsFor } from "@/lib/assistant/tools";
import { cleanReminders } from "@/lib/assistant/tools/reminders";
import {
  NO_REMINDERS,
  resolveSuggestions,
  type SuggestionOp,
  suggestionsSummary,
} from "@/lib/assistant/tools/suggestions";
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
    { id: "L-school", title: "School" },
  ],
  items: [],
};
const reminders = () => cleanReminders(REMINDERS)!;
const CONTEXT = { today: "2026-11-02", year: 2026, lang: "en", page: "overview" };
const LETTER = {
  kind: "file",
  name: "Scan.txt",
  text: "Elternbrief Klasse 3b\nLiebe Eltern, am Montag feiern wir unser Schulfest …",
};

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Res = { ok: boolean; result: any; summary: string; suggestions?: any };

function toolCtx(t: AssistantTest, withReminders = true, lang: "en" | "de" = "en"): ToolContext {
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
    ...(withReminders ? { reminders: reminders() } : {}),
  };
}

async function setup(worker = true) {
  const t = assistantTest({ worker });
  current.push(t);
  return t;
}

const errorOf = (items: unknown, withReminders = true) => {
  try {
    resolveSuggestions({ reminders: withReminders ? reminders() : undefined }, items);
  } catch (e) {
    return (e as Error).message;
  }
  return "ok";
};

describe("suggest_items", () => {
  it("is offered whenever changes are allowed, with or without the Reminders", () => {
    const names = (opts: Parameters<typeof toolsFor>[0]) => toolsFor(opts).map((t) => t.function.name);
    expect(names({ writes: true, search: false })).toContain("suggest_items");
    expect(names({ writes: true, search: false, reminders: true })).toContain("suggest_items");
    expect(names({ writes: false, search: false, reminders: true })).not.toContain("suggest_items");
  });

  it("resolves the items", () => {
    expect(
      resolveSuggestions({ reminders: reminders() }, [
        {
          kind: "event",
          title: " Sports day ",
          date: "2026-11-09",
          endDate: "2026-11-09",
          start: "08:00",
          end: "13:00",
          location: " Stadium ",
          person: "Mia",
          note: "",
          list: "ignored",
        },
        { kind: "event", title: "Class trip", date: "2026-11-12", endDate: "2026-11-14", end: "", note: "Bring a sleeping bag" },
        { kind: "task", title: "Bring a cake" },
        { kind: "task", title: "Buy glue", date: "2026-11-05", start: "07:30", list: "shopping" },
        { kind: "deadline", title: "Return the form", date: "2026-11-06", list: "school", note: "Signed" },
        { kind: "deadline", title: "Pay the trip", date: "2026-11-06", start: "12:00", list: "L-shop" },
      ]),
    ).toEqual([
      { op: "event", title: "Sports day", date: "2026-11-09", start: "08:00", end: "13:00", location: "Stadium", person: "Mia" },
      { op: "event", title: "Class trip", date: "2026-11-12", endDate: "2026-11-14", note: "Bring a sleeping bag" },
      { op: "task", title: "Bring a cake", list: null, listTitle: null },
      { op: "task", title: "Buy glue", due: "2026-11-05T07:30", list: "L-shop", listTitle: "Groceries" },
      { op: "deadline", title: "Return the form", due: "2026-11-06", note: "Signed", list: "L-school", listTitle: "School" },
      { op: "deadline", title: "Pay the trip", due: "2026-11-06T12:00", list: "L-shop", listTitle: "Groceries" },
    ] satisfies SuggestionOp[]);
  });

  it("refuses items Ohana or the Reminders wouldn't take", () => {
    const event = { kind: "event", title: "Party", date: "2026-11-09" };
    expect(errorOf([])).toBe("items must be a list of 1 to 30 suggestions");
    expect(errorOf("x")).toMatch(/1 to 30/);
    expect(errorOf(Array.from({ length: 31 }, () => event))).toMatch(/1 to 30/);
    expect(errorOf(Array.from({ length: 30 }, () => event))).toBe("ok");
    expect(errorOf([event, { kind: "event", title: "Party" }])).toBe("items[1]: date is required (YYYY-MM-DD)");
    expect(errorOf([{ ...event, date: "2026-02-30" }])).toBe("items[0]: date must be YYYY-MM-DD");
    expect(errorOf([{ ...event, endDate: "2026-11-08" }])).toBe("items[0]: endDate must not be before date");
    expect(errorOf([{ ...event, start: "9:00" }])).toBe("items[0]: start must be HH:MM");
    expect(errorOf([{ ...event, start: "24:00" }])).toBe("items[0]: start must be HH:MM");
    expect(errorOf([{ ...event, end: "10:00" }])).toBe("items[0]: end needs start");
    expect(errorOf([{ ...event, start: "10:00", end: "09:00" }])).toBe("items[0]: end must be after start");
    // Over midnight into the next day is fine.
    expect(errorOf([{ ...event, endDate: "2026-11-10", start: "22:00", end: "01:00" }])).toBe("ok");
    expect(errorOf([{ ...event, title: "  " }])).toBe("items[0]: title must not be empty");
    expect(errorOf([{ ...event, title: "x".repeat(201) }])).toBe("items[0]: title takes at most 200 characters");
    expect(errorOf([{ ...event, location: "x".repeat(201) }])).toBe("items[0]: location takes at most 200 characters");
    expect(errorOf([{ ...event, person: "x".repeat(81) }])).toBe("items[0]: person takes at most 80 characters");
    expect(errorOf([{ ...event, note: "x".repeat(1001) }])).toBe("items[0]: note takes at most 1000 characters");
    expect(errorOf([{ ...event, note: 7 }])).toBe("items[0]: note must be text");
    expect(errorOf([{ kind: "todo", title: "x" }])).toBe("items[0]: kind must be event, task or deadline");
    expect(errorOf([{ kind: "deadline", title: "Reply" }])).toBe("items[0]: date is required (YYYY-MM-DD)");
    expect(errorOf([{ kind: "task", title: "Bring", start: "08:00" }])).toBe("items[0]: start (the due time) needs date");
    expect(errorOf([{ kind: "task", title: "Bring", list: "Work" }])).toMatch(/^items\[0\]: No Reminders list "Work". The lists are: “Groceries”, “School”/);
    // Without the user's Reminders: events only.
    expect(errorOf([event], false)).toBe("ok");
    expect(errorOf([event, { kind: "task", title: "Bring a cake" }], false)).toBe(`items[1]: ${NO_REMINDERS}`);
    expect(errorOf([{ kind: "deadline", title: "Reply", date: "2026-11-06" }], false)).toBe(
      "items[0]: The user's Reminders aren't available on this device: suggest a deadline as an all-day event instead and mention tasks in your answer",
    );
  });

  it("sums the suggestions up for the card", () => {
    const ops = resolveSuggestions({ reminders: reminders() }, [
      { kind: "event", title: "Sports day", date: "2026-11-09" },
      { kind: "deadline", title: "Reply", date: "2026-11-06" },
      { kind: "event", title: "Trip", date: "2026-11-12" },
      { kind: "task", title: "Bring a cake" },
    ]);
    expect(suggestionsSummary(ops, "en")).toBe("2 events, 1 task, 1 deadline");
    expect(suggestionsSummary(ops, "de")).toBe("2 Termine, 1 Aufgabe, 1 Frist");
    expect(suggestionsSummary(ops, "en", "Elternbrief 3b")).toBe("From “Elternbrief 3b”: 2 events, 1 task, 1 deadline");
    expect(suggestionsSummary(ops, "de", "Elternbrief 3b")).toBe("Aus „Elternbrief 3b“: 2 Termine, 1 Aufgabe, 1 Frist");
    expect(suggestionsSummary([ops[1], ops[1], ops[3], ops[3]], "de")).toBe("2 Aufgaben, 2 Fristen");
    expect(suggestionsSummary([ops[0]], "en")).toBe("Add “Sports day”");
    expect(suggestionsSummary([ops[0]], "de")).toBe("„Sports day“ hinzufügen");
    expect(suggestionsSummary([ops[0]], "en", "Invitation")).toBe("From “Invitation”: Add “Sports day”");
    expect(suggestionsSummary([ops[0]], "de", "Einladung")).toBe("Aus „Einladung“: „Sports day“ hinzufügen");
  });

  it("gives the resolved suggestions to wait for, not a result", async () => {
    const t = await setup(false);
    const run = (args: unknown, ctx = toolCtx(t)) =>
      runTool("suggest_items", JSON.stringify(args), ctx, new Set(Object.keys(TOOLS))) as Promise<Res>;
    const res = await run({ source: "  Elternbrief 3b ", items: [{ kind: "task", title: "Bring a cake", date: "2026-11-05" }] });
    expect(res).toEqual({
      ok: true,
      result: { waiting: true },
      summary: "From “Elternbrief 3b”: Add “Bring a cake”",
      suggestions: {
        summary: "From “Elternbrief 3b”: Add “Bring a cake”",
        source: "Elternbrief 3b",
        ops: [{ op: "task", title: "Bring a cake", due: "2026-11-05", list: null, listTitle: null }],
      },
    });
    const de = await run({ items: [{ kind: "event", title: "Schulfest", date: "2026-11-09" }] }, toolCtx(t, true, "de"));
    expect(de.suggestions).toEqual({ summary: "„Schulfest“ hinzufügen", ops: [{ op: "event", title: "Schulfest", date: "2026-11-09" }] });
    const bad = await run({ items: [{ kind: "task", title: "Bring a cake" }] }, toolCtx(t, false));
    expect(bad.ok).toBe(false);
    expect(bad.suggestions).toBeUndefined();
    expect(bad.result.error).toBe(`items[0]: ${NO_REMINDERS}`);
    expect((await run({ source: "x".repeat(201), items: [{ kind: "event", title: "x", date: "2026-11-09" }] })).result.error).toBe(
      "source takes at most 200 characters",
    );
  });

  it("only suggests events POST /events accepts as they are", async () => {
    const t = await setup(false);
    const ops = resolveSuggestions({}, [
      { kind: "event", title: "Sports day", date: "2026-11-09", start: "08:00", end: "13:00", location: "Stadium", person: "Mia", note: "Trainers" },
      { kind: "event", title: "Class trip", date: "2026-11-12", endDate: "2026-11-14", start: "07:00", end: "18:00" },
      { kind: "event", title: "Closed", date: "2026-11-20" },
    ]);
    for (const op of ops) {
      const { op: _, ...fields } = op;
      const res = await t.call("POST", `/families/${t.familyId}/events`, fields);
      expect(res.status, JSON.stringify(res.data)).toBe(201);
      expect(res.data).toMatchObject({ title: op.title, date: (fields as { date: string }).date });
    }
  });
});

describe("suggestions in a chat", () => {
  async function chatWith(t: AssistantTest, body: Record<string, unknown>) {
    const res = await t.call("POST", `${t.ai}/chats`, { ...CONTEXT, ...body });
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

  it("waits for the user, and goes on with what they added", async () => {
    const t = await setup();
    await configure(t);
    const id = await chatWith(t, { text: "What's in it?", attachments: [LETTER], reminders: REMINDERS });
    expect(net.aiBody.messages[0].content).toMatch(/## Letters, notes and invitations\nWhen the user shares a letter/);
    expect(net.aiBody.messages[0].content).not.toMatch(/suggest only events/);
    let list = await items(t, id);
    const edit = list.at(-1);
    expect(edit).toEqual({
      kind: "suggestions",
      id: expect.any(String),
      summary: "From “Elternbrief”: 1 event, 1 task, 1 deadline",
      source: "Elternbrief",
      ops: [
        { op: "event", title: "School party", date: "2026-11-09", start: "15:00", end: "17:00", location: "Schoolyard" },
        { op: "task", title: "Bring a cake", due: "2026-11-07", list: null, listTitle: null },
        { op: "deadline", title: "Return the consent form", due: "2026-11-05T12:00", note: "Signed by a parent", list: null, listTitle: null },
      ],
    });
    expect(list.some((it) => it.kind === "tool")).toBe(false);
    // Only the waiting suggestions can be answered, and only on their own route.
    expect((await t.call("POST", `${t.ai}/chats/${id}/suggestions`, { id: "nope", applied: false, ...CONTEXT })).status).toBe(409);
    expect((await t.call("POST", `${t.ai}/chats/${id}/reminders`, { id: edit.id, applied: false, ...CONTEXT })).status).toBe(409);
    expect((await t.call("POST", `${t.ai}/chats/${id}/calendar`, { id: edit.id, applied: false, ...CONTEXT })).status).toBe(409);
    expect((await t.call("POST", `${t.ai}/chats/${id}/suggestions`, { id: edit.id, applied: true, ...CONTEXT })).status).toBe(400);

    const res = await t.call("POST", `${t.ai}/chats/${id}/suggestions`, {
      id: edit.id,
      applied: true,
      results: [{ ok: true, id: "ev-1", extra: "dropped" }, { ok: false, declined: true, error: "ignored" }, { ok: false, error: "No access" }],
      reminders: REMINDERS,
      ...CONTEXT,
    });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    list = await items(t, id);
    expect(list.find((it) => it.kind === "suggestions").answer).toEqual({
      applied: true,
      results: [{ ok: true, id: "ev-1" }, { ok: false, declined: true }, { ok: false, error: "No access" }],
    });
    expect(list.at(-1)).toEqual({ kind: "assistant", text: "Added 1 of 3 suggestions." });
    expect(JSON.parse(String((await toolMessage(t, id, edit.id))?.content))).toEqual({
      applied: true,
      results: [
        { op: "event", title: "School party", ok: true, id: "ev-1" },
        { op: "task", title: "Bring a cake", ok: false, declined: true },
        { op: "deadline", title: "Return the consent form", ok: false, error: "No access" },
      ],
    });
    expect((await t.call("POST", `${t.ai}/chats/${id}/suggestions`, { id: edit.id, applied: false, ...CONTEXT })).status).toBe(409);
  });

  it("tells the model when the user declined them", async () => {
    const t = await setup();
    await configure(t);
    // Without the Reminders the assistant suggests events only.
    const id = await chatWith(t, { text: "Here's the letter" });
    expect(net.aiBody.messages[0].content).toMatch(/Reminders aren't available: suggest only events/);
    const edit = (await items(t, id)).at(-1);
    expect(edit).toMatchObject({ kind: "suggestions", summary: "From “Elternbrief”: Add “School party”", ops: [{ op: "event" }] });
    await t.call("POST", `${t.ai}/chats/${id}/suggestions`, { id: edit.id, applied: false, ...CONTEXT });
    const list = await items(t, id);
    expect(list.find((it) => it.id === edit.id).answer).toEqual({ applied: false });
    expect(list.at(-1).text).toBe("OK, I added nothing.");
    expect(JSON.parse(String((await toolMessage(t, id, edit.id))?.content))).toEqual({
      applied: false,
      note: "The user declined these suggestions: nothing was added to their calendar or Reminders.",
    });
  });

  it("is skipped by a new message", async () => {
    const t = await setup();
    await configure(t);
    const id = await chatWith(t, { text: "Elternbrief", reminders: REMINDERS });
    const edit = (await items(t, id)).at(-1);
    expect(edit.kind).toBe("suggestions");
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "never mind", ...CONTEXT });
    const list = await items(t, id);
    expect(list.find((it) => it.id === edit.id).skipped).toBe(true);
    expect(JSON.parse(String((await toolMessage(t, id, edit.id))?.content))).toEqual({
      skipped: true,
      note: "The user neither added nor declined these suggestions and wrote a new message instead: nothing was added to their calendar or Reminders.",
    });
    expect((await t.call("POST", `${t.ai}/chats/${id}/suggestions`, { id: edit.id, applied: true, results: [], ...CONTEXT })).status).toBe(409);
  });

  it("isn't offered to viewers, nor without changes", async () => {
    const t = await setup();
    await configure(t);
    const res = await t.view("POST", `${t.ai}/chats`, { text: "the letter", ...CONTEXT, reminders: REMINDERS });
    expect(res.status).toBe(200);
    const sent = (net.aiBody.tools ?? []).map((x: { function: { name: string } }) => x.function.name);
    expect(sent).not.toContain("suggest_items");
    expect(net.aiBody.messages[0].content).not.toMatch(/## Letters, notes and invitations/);
  });

  it("comes along with an imported chat, checked", async () => {
    const t = await setup();
    const res = await t.call("POST", `${t.ai}/chats/import`, {
      title: "Old",
      items: [
        { kind: "user", text: "the letter", attachments: [{ kind: "file", name: "Scan.txt" }] },
        {
          kind: "suggestions",
          id: "s1",
          summary: "From “Elternbrief”: Add “School party”",
          source: "Elternbrief",
          ops: [{ op: "event", title: "School party", date: "2026-11-09" }, 7],
          answer: { applied: true, results: [{ ok: false, declined: true }, { ok: true, id: "x" }] },
        },
        { kind: "suggestions", id: "s2", summary: "Add “Bring a cake”", source: 5, ops: [] },
        { kind: "suggestions", id: "s3", summary: "x", source: "y".repeat(300), ops: [], answer: { applied: false } },
      ],
      history: [],
    });
    expect(res.status, JSON.stringify(res.data)).toBe(201);
    const got = (await t.call("GET", `${t.ai}/chats/${res.data.chat.id}`)).data.items;
    expect(got[1]).toEqual({
      kind: "suggestions",
      id: "s1",
      summary: "From “Elternbrief”: Add “School party”",
      source: "Elternbrief",
      ops: [{ op: "event", title: "School party", date: "2026-11-09" }],
      answer: { applied: true, results: [{ ok: false, declined: true }, { ok: true, id: "x" }] },
    });
    expect(got[2]).toEqual({ kind: "suggestions", id: "s2", summary: "Add “Bring a cake”", ops: [], skipped: true });
    expect(got[3].source).toBe("y".repeat(200));
  });
});
