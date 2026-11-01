// Reading a scanned letter (POST /ai/letter, lib/assistant/letter.ts): one completion with the
// family's model whose JSON answer becomes suggest_items' ops (tasks and deadlines to the
// default Reminders list); wrong items are dropped one by one. The model is the mock AI.

import { afterEach, describe, expect, it } from "vitest";
import { handleDisabledModules } from "@/lib/api/disabled-modules";
import { createFamilyApi } from "@/lib/api/family-api";
import { letterInput, letterPrompt, MAX_LETTER_TEXT, parseLetterAnswer } from "@/lib/assistant/letter";
import { handleAi } from "@/lib/assistant/routes";
import { MAX_SUGGESTIONS, NO_REMINDERS, resolveSuggestion } from "@/lib/assistant/tools/suggestions";
import { addPerson } from "@/lib/families/people";
import { AI, type AssistantTest, assistantTest, BASE, configure, net } from "@/lib/test/assistant";
import { NOW } from "@/lib/test/factories";

let current: AssistantTest[] = [];
afterEach(async () => {
  delete process.env.DISABLED_MODULES;
  await Promise.all(current.map((t) => t.stop()));
  current = [];
});

function setup() {
  const t = assistantTest({ worker: false });
  current.push(t);
  return t;
}

const LETTER = "Elternbrief Klasse 3b\nLiebe Eltern, am Montag feiern wir unser Schulfest …";

describe("POST /ai/letter", () => {
  it("answers ai: false without AI settings", async () => {
    const t = setup();
    const res = await t.call("POST", `${t.ai}/letter`, { text: LETTER });
    expect(res.status).toBe(200);
    expect(res.data).toEqual({ ai: false, items: [] });
  });

  it("returns the letter's events, tasks and deadlines", async () => {
    const t = setup();
    await configure(t);
    const res = await t.call("POST", `${t.ai}/letter`, { text: LETTER, today: "2026-11-02" });
    expect(res.status).toBe(200);
    expect(res.data).toEqual({
      ai: true,
      source: "Elternbrief Klasse 3b",
      items: [
        {
          op: "event",
          title: "School party",
          date: "2026-11-09",
          start: "15:00",
          end: "17:00",
          location: "Schoolyard",
          person: expect.any(String),
        },
        { op: "task", title: "Bring a cake", due: "2026-11-07", list: null, listTitle: null },
        {
          op: "deadline",
          title: "Return the consent form",
          due: "2026-11-05T12:00",
          note: "Signed by a parent",
          list: null,
          listTitle: null,
        },
      ],
    });
    // One completion: the instructions, then the letter as the user's message.
    const [system, user] = net.aiBody.messages;
    expect(system.role).toBe("system");
    expect(system.content).toMatch(/^Today is Monday, 2026-11-02\.$/m);
    expect(system.content).toMatch(/Answer in English/);
    expect(user).toEqual({ role: "user", content: LETTER });
    expect(net.aiBody.tools).toBeUndefined();
  });

  it("names the family and answers in the language asked", async () => {
    const t = setup();
    await configure(t);
    addPerson(t.db, { id: t.editor.id }, t.familyId, { name: "Aaron", birthday: "2018-03-01" }, NOW);
    const res = await t.call("POST", `${t.ai}/letter`, { text: LETTER, today: "2026-11-02", lang: "de" });
    expect(res.status).toBe(200);
    expect(net.aiBody.messages[0].content).toMatch(/Aaron \(8\)/);
    expect(net.aiBody.messages[0].content).toMatch(/Answer in German/);
    expect(res.data.items.map((i: { title: string }) => i.title)).toEqual([
      "Schulfest",
      "Kuchen mitbringen",
      "Einverständniserklärung abgeben",
    ]);
    expect(res.data.items[0].person).toBe("Aaron");
  });

  it("drops the items the model got wrong", async () => {
    const t = setup();
    await configure(t);
    const res = await t.call("POST", `${t.ai}/letter`, { text: `${LETTER}\nsloppy`, today: "2026-11-02" });
    expect(res.status).toBe(200);
    expect(res.data.items.map((i: { op: string }) => i.op)).toEqual(["event", "task", "deadline"]);
    const none = await t.call("POST", `${t.ai}/letter`, { text: "A letter about nothing" });
    expect(none.data).toEqual({ ai: true, source: "A letter about nothing", items: [] });
  });

  it("is for editors, with a text", async () => {
    const t = setup();
    await configure(t);
    expect((await t.view("POST", `${t.ai}/letter`, { text: LETTER })).status).toBe(403);
    for (const body of [{}, { text: "  " }, { text: 7 }, { text: "x".repeat(MAX_LETTER_TEXT + 1) }, { text: LETTER, today: "2026-02-30" }]) {
      const res = await t.call("POST", `${t.ai}/letter`, body);
      expect(res.status, JSON.stringify(body).slice(0, 60)).toBe(400);
    }
    expect((await t.call("POST", `${t.ai}/letter`, { text: "x".repeat(MAX_LETTER_TEXT) })).status).toBe(200);
  });

  it("surfaces the model's failures as 502", async () => {
    const t = setup();
    await configure(t, { baseUrl: `${AI}/missing` });
    // The endpoint answers 404: its error, as a 502.
    const res = await t.call("POST", `${t.ai}/letter`, { text: LETTER });
    expect(res.status).toBe(502);
    expect(res.data.error).toMatch(/refused/);
  });

  it("is off with the assistant", async () => {
    const t = setup();
    await configure(t);
    const handler = createFamilyApi([handleDisabledModules, handleAi(t.env)], { db: t.db, appUrl: "http://ohana.test" });
    process.env.DISABLED_MODULES = "assistant";
    const res = await handler(
      new Request(`${BASE}${t.ai}/letter`, {
        method: "POST",
        headers: { authorization: `Bearer ${t.editor.token}`, "content-type": "application/json" },
        body: JSON.stringify({ text: LETTER }),
      }),
    );
    expect(res.status).toBe(404);
  });
});

describe("the letter's answer", () => {
  it("is read from JSON, alone or in prose, and capped", () => {
    const event = { kind: "event", title: "Party", date: "2026-11-09" };
    expect(parseLetterAnswer(JSON.stringify({ source: " Note ", items: [event] }))).toEqual({
      source: "Note",
      items: [{ op: "event", title: "Party", date: "2026-11-09" }],
    });
    expect(parseLetterAnswer(`Sure: [${JSON.stringify(event)}]`).items).toHaveLength(1);
    expect(parseLetterAnswer(JSON.stringify({ items: "none" }))).toEqual({ items: [] });
    expect(parseLetterAnswer(JSON.stringify({ source: "x".repeat(300), items: [] })).source).toHaveLength(200);
    const many = Array.from({ length: 40 }, () => event);
    expect(parseLetterAnswer(JSON.stringify({ items: many })).items).toHaveLength(MAX_SUGGESTIONS);
    expect(() => parseLetterAnswer("I couldn't read it.")).toThrow(/not valid JSON/);
  });

  it("puts tasks on the default list, ignoring a list the model names", () => {
    expect(resolveSuggestion({}, { kind: "task", title: "Bring", list: "School" }, { defaultList: true })).toEqual({
      op: "task",
      title: "Bring",
      list: null,
      listTitle: null,
    });
    // The chat's tool still needs the Reminders for them.
    expect(() => resolveSuggestion({}, { kind: "task", title: "Bring" })).toThrow(NO_REMINDERS);
  });

  it("checks the body", () => {
    const now = new Date("2026-11-02T22:30:00Z");
    expect(letterInput({ text: " Hi " }, now)).toEqual({ text: "Hi", today: "2026-11-02", lang: "en" });
    expect(letterInput({ text: "Hi", today: "2027-01-05", lang: "de" }, now)).toEqual({
      text: "Hi",
      today: "2027-01-05",
      lang: "de",
    });
    expect(() => letterInput({ text: "Hi", today: "tomorrow" }, now)).toThrow(/today/);
    expect(letterPrompt({ today: "2026-11-02", lang: "en", people: [] })).toMatch(/aren't known/);
  });
});
