// The assistant's Apple Calendar tools (lib/assistant/tools/apple-calendar.ts): the snapshot the
// app sends with every message (`appleCalendar` in the chat's context), get_apple_calendar, and
// edit_apple_calendar, which waits for the user to apply or decline the change in the app
// (POST …/calendar) like a Reminders edit.

import { afterEach, describe, expect, it } from "vitest";
import { cleanContext } from "@/lib/assistant/chat";
import type { NetOptions } from "@/lib/assistant/net";
import { runTool, type ToolContext, TOOLS, toolsFor } from "@/lib/assistant/tools";
import { calendarEditSummary, cleanAppleCalendar, resolveCalendarOps } from "@/lib/assistant/tools/apple-calendar";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { type AssistantTest, assistantTest, configure, type Event, net } from "@/lib/test/assistant";

let current: AssistantTest[] = [];
afterEach(async () => {
  await Promise.all(current.map((t) => t.stop()));
  current = [];
});

const CALENDAR = {
  from: "2026-10-26",
  to: "2027-01-31",
  calendars: [
    { id: "C-fam", title: "Family", account: "iCloud", writable: true, ohana: true },
    { id: "C-work", title: "Work", account: "Exchange", writable: true },
    { id: "C-hol", title: "Holidays", account: "Subscribed", writable: false },
  ],
  events: [
    { id: "E2", calendar: "C-work", title: "Standup", allDay: false, start: "2026-11-05T09:00", end: "2026-11-05T09:15", rrule: "freq=weekly;byday=th" },
    { id: "E2@2026-11-12", calendar: "C-work", title: "Standup", allDay: false, start: "2026-11-12T09:00", end: "2026-11-12T09:15", rrule: "FREQ=WEEKLY;BYDAY=TH" },
    { id: "E1", calendar: "C-fam", title: "Dentist", allDay: false, start: "2026-11-03T10:00", end: "2026-11-03T11:30", location: "Main St 1" },
    { id: "E3", calendar: "C-fam", title: "Trip", allDay: true, start: "2026-11-20", end: "2026-11-22", notes: "Pack" },
    { id: "H1", calendar: "C-hol", title: "Holiday", allDay: true, start: "2026-12-25", end: "2026-12-25" },
  ],
};
const snapshot = () => cleanAppleCalendar(CALENDAR)!;
const CONTEXT = { today: "2026-11-02", year: 2026, lang: "en", page: "calendar" };

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Res = { ok: boolean; result: any; summary: string; appleCalendar?: any };

function toolCtx(t: AssistantTest, appleCalendar = snapshot()): ToolContext {
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
    appleCalendar,
  };
}

async function setup(worker = true) {
  const t = assistantTest({ worker });
  current.push(t);
  return t;
}

const errorOf = (ops: unknown, s = snapshot()) => {
  try {
    resolveCalendarOps(s, ops);
  } catch (e) {
    return (e as Error).message;
  }
  return "ok";
};

describe("the device calendars in the chat's context", () => {
  it("are checked, sorted and capped", () => {
    expect(cleanAppleCalendar(undefined)).toBeUndefined();
    expect(cleanAppleCalendar([])).toBeUndefined();
    const s = snapshot();
    expect(s.from).toBe("2026-10-26");
    expect(s.calendars[0]).toEqual({ id: "C-fam", title: "Family", account: "iCloud", writable: true, ohana: true });
    expect(s.calendars[2]).toEqual({ id: "C-hol", title: "Holidays", account: "Subscribed", writable: false });
    // Sorted by start; rules normalized.
    expect(s.events.map((e) => e.id)).toEqual(["E1", "E2", "E2@2026-11-12", "E3", "H1"]);
    expect(s.events[1].rrule).toBe("FREQ=WEEKLY;BYDAY=TH");

    const r = cleanAppleCalendar({
      from: "2026-13-01",
      calendars: [
        ...Array.from({ length: 120 }, (_, i) => ({ id: `C${i}`, title: `Cal ${i}`, writable: i % 2 === 0 })),
        { id: "C0", title: "Twice" },
      ],
      events: [
        { id: "a", calendar: "C0", title: "x".repeat(300), notes: "n".repeat(1500), location: "l".repeat(400), start: "2026-11-02T08:00", end: "2026-11-02T09:00", rrule: "FREQ=HOURLY" },
        { id: "b", calendar: "C-unknown", title: "No calendar", start: "2026-11-02", end: "2026-11-02" },
        { id: "a", calendar: "C0", title: "Twice", start: "2026-11-02", end: "2026-11-02" },
        { id: "c", calendar: "C1", title: "Ends before", start: "2026-11-02T10:00", end: "2026-11-02T09:00" },
        { id: "d", calendar: "C1", title: "Bad day", start: "2026-02-30", end: "2026-02-30" },
        { id: "e", calendar: "C1", title: "All day by flag", allDay: true, start: "2026-11-04T10:00", end: "2026-11-05T12:00" },
        { id: "f", calendar: "C1", title: "Timed, date end", start: "2026-11-04T10:00", end: "2026-11-05" },
        { id: "x".repeat(301), calendar: "C1", title: "Long id", start: "2026-11-04", end: "2026-11-04" },
        ...Array.from({ length: 1100 }, (_, i) => ({ id: `i${i}`, calendar: "C2", title: `Event ${i}`, allDay: true, start: "2026-12-01", end: "2026-12-01" })),
      ],
    })!;
    expect(r.from).toBeNull();
    expect(r.calendars).toHaveLength(100);
    expect(r.calendars[1]).toEqual({ id: "C1", title: "Cal 1", writable: false });
    expect(r.events).toHaveLength(1000);
    expect(r.events[0]).toEqual({
      id: "a",
      calendar: "C0",
      title: "x".repeat(200),
      allDay: false,
      start: "2026-11-02T08:00",
      end: "2026-11-02T09:00",
      location: "l".repeat(300),
      notes: "n".repeat(1000),
    });
    expect(r.events[1]).toEqual({ id: "e", calendar: "C1", title: "All day by flag", allDay: true, start: "2026-11-04", end: "2026-11-05" });
    expect(r.events.map((e) => e.id)).not.toContain("f");
  });

  it("are kept in the context only when the app sent them", () => {
    expect(cleanContext({ ...CONTEXT })).not.toHaveProperty("appleCalendar");
    expect(cleanContext({ ...CONTEXT, appleCalendar: CALENDAR }).appleCalendar).toEqual(snapshot());
  });
});

describe("the Apple Calendar tools", () => {
  it("are offered only with the device calendars, and to viewers only for reading", () => {
    const names = (opts: Parameters<typeof toolsFor>[0]) => toolsFor(opts).map((t) => t.function.name);
    expect(names({ writes: true, search: false, reminders: true })).not.toContain("get_apple_calendar");
    expect(names({ writes: true, search: false })).not.toContain("edit_apple_calendar");
    expect(names({ writes: true, search: false, appleCalendar: true })).toEqual(
      expect.arrayContaining(["get_apple_calendar", "edit_apple_calendar"]),
    );
    const read = names({ writes: false, search: false, appleCalendar: true });
    expect(read).toContain("get_apple_calendar");
    expect(read).not.toContain("edit_apple_calendar");
  });

  it("read the calendars and events, by range and calendar", async () => {
    const t = await setup(false);
    const tool = async (args: unknown, ctx = toolCtx(t)) =>
      (await runTool("get_apple_calendar", JSON.stringify(args), ctx, new Set(Object.keys(TOOLS)))) as Res;
    const all = await tool({});
    expect(all.result.from).toBe("2026-10-26");
    expect(all.result.calendars).toHaveLength(3);
    expect(all.result.events.map((e: { id: string }) => e.id)).toEqual(["E1", "E2", "E2@2026-11-12", "E3", "H1"]);
    expect(all.summary).toBe("5 events");
    // Overlapping the range: the trip of 20–22 Nov is on the 21st.
    expect((await tool({ from: "2026-11-21", to: "2026-11-30" })).result.events.map((e: { id: string }) => e.id)).toEqual(["E3"]);
    expect((await tool({ calendar: "work" })).result.events.map((e: { id: string }) => e.id)).toEqual(["E2", "E2@2026-11-12"]);
    const wide = await tool({ from: "2026-01-01" });
    expect(wide.result.note).toBe("The app sent only the events from 2026-10-26 to 2027-01-31");
    expect((await tool({ calendar: "Private" })).result.error).toMatch(/^No calendar "Private". The calendars are: “Family”, “Work”, “Holidays”/);
    expect((await tool({ from: "2026-12-01", to: "2026-11-01" })).result.error).toBe("to must not be before from");
    const without = { ...toolCtx(t), appleCalendar: undefined };
    expect((await runTool("get_apple_calendar", "{}", without, new Set(Object.keys(TOOLS)))).result).toEqual({
      error: "The user's device calendars aren't available in this chat",
    });
  });

  it("resolve an edit's ops against the snapshot", () => {
    expect(
      resolveCalendarOps(snapshot(), [
        { op: "add", calendar: "family", title: " Dentist ", start: "2026-11-05T09:00", location: "Main St 1" },
        { op: "add", calendar: "C-work", title: "Offsite", start: "2026-11-10", end: "2026-11-11", notes: "Bus" },
        { op: "add", calendar: "Work", title: "Gym", start: "2026-11-09T18:00", end: "2026-11-09T19:30", rrule: "freq=weekly;byday=mo" },
        { op: "add", calendar: "Work", title: "Day", start: "2026-11-09T18:00", allDay: true },
        { op: "update", id: "E1", start: "2026-11-04T14:00" },
        { op: "update", id: "E3", start: "2026-11-27", calendar: "Work", title: "Weekend trip" },
        { op: "update", id: "E2@2026-11-12", span: "future", location: "Room 2", notes: null },
        { op: "update", id: "E1", allDay: true },
        { op: "update", id: "E3", start: "2026-11-21T08:00" },
        { op: "delete", id: "E2@2026-11-12" },
        { op: "delete", id: "E1", span: "future" },
      ]),
    ).toEqual([
      { op: "add", calendar: "C-fam", calendarTitle: "Family", title: "Dentist", start: "2026-11-05T09:00", end: "2026-11-05T10:00", allDay: false, location: "Main St 1" },
      { op: "add", calendar: "C-work", calendarTitle: "Work", title: "Offsite", start: "2026-11-10", end: "2026-11-11", allDay: true, notes: "Bus" },
      { op: "add", calendar: "C-work", calendarTitle: "Work", title: "Gym", start: "2026-11-09T18:00", end: "2026-11-09T19:30", allDay: false, rrule: "FREQ=WEEKLY;BYDAY=MO" },
      { op: "add", calendar: "C-work", calendarTitle: "Work", title: "Day", start: "2026-11-09", end: "2026-11-09", allDay: true },
      // A new start keeps the length (1:30).
      {
        op: "update", id: "E1", eventTitle: "Dentist", eventStart: "2026-11-03T10:00", eventEnd: "2026-11-03T11:30", eventAllDay: false,
        calendar: "C-fam", calendarTitle: "Family", start: "2026-11-04T14:00", end: "2026-11-04T15:30", allDay: false,
      },
      // Moved to another calendar, three days long still.
      {
        op: "update", id: "E3", eventTitle: "Trip", eventStart: "2026-11-20", eventEnd: "2026-11-22", eventAllDay: true,
        calendar: "C-work", calendarTitle: "Work", title: "Weekend trip", start: "2026-11-27", end: "2026-11-29", allDay: true,
      },
      {
        op: "update", id: "E2@2026-11-12", eventTitle: "Standup", eventStart: "2026-11-12T09:00", eventEnd: "2026-11-12T09:15", eventAllDay: false,
        calendar: "C-work", calendarTitle: "Work", span: "future", location: "Room 2", notes: "",
      },
      {
        op: "update", id: "E1", eventTitle: "Dentist", eventStart: "2026-11-03T10:00", eventEnd: "2026-11-03T11:30", eventAllDay: false,
        calendar: "C-fam", calendarTitle: "Family", start: "2026-11-03", end: "2026-11-03", allDay: true,
      },
      {
        op: "update", id: "E3", eventTitle: "Trip", eventStart: "2026-11-20", eventEnd: "2026-11-22", eventAllDay: true,
        calendar: "C-fam", calendarTitle: "Family", start: "2026-11-21T08:00", end: "2026-11-21T09:00", allDay: false,
      },
      {
        op: "delete", id: "E2@2026-11-12", eventTitle: "Standup", eventStart: "2026-11-12T09:00", eventEnd: "2026-11-12T09:15", eventAllDay: false,
        calendar: "C-work", calendarTitle: "Work", span: "this",
      },
      // span only for an occurrence of a repeating event.
      {
        op: "delete", id: "E1", eventTitle: "Dentist", eventStart: "2026-11-03T10:00", eventEnd: "2026-11-03T11:30", eventAllDay: false,
        calendar: "C-fam", calendarTitle: "Family",
      },
    ]);
  });

  it("refuse ops that don't fit the snapshot", () => {
    expect(errorOf([])).toMatch(/1 to 50 changes/);
    expect(errorOf(Array.from({ length: 51 }, () => ({ op: "add", calendar: "Work", title: "x", start: "2026-11-02" })))).toMatch(/1 to 50/);
    expect(errorOf([{ op: "delete", id: "E9" }])).toBe('ops[0]: No event with the id "E9" (get_apple_calendar gives the ids)');
    expect(errorOf([{ op: "add", calendar: "Work", title: "ok", start: "2026-11-02" }, { op: "delete" }])).toMatch(/^ops\[1\]: id is required/);
    expect(errorOf([{ op: "delete", id: "H1" }])).toBe("ops[0]: The calendar “Holidays” is read-only: its events can't be changed");
    expect(errorOf([{ op: "add", calendar: "Holidays", title: "x", start: "2026-11-02" }])).toMatch(/“Holidays” is read-only/);
    expect(errorOf([{ op: "update", id: "E1", calendar: "Holidays" }])).toMatch(/“Holidays” is read-only/);
    expect(errorOf([{ op: "add", calendar: "Private", title: "x", start: "2026-11-02" }])).toMatch(/^ops\[0\]: No calendar "Private"/);
    expect(errorOf([{ op: "add", title: "x", start: "2026-11-02" }])).toBe("ops[0]: calendar is required");
    expect(errorOf([{ op: "add", calendar: "Work", title: " ", start: "2026-11-02" }])).toBe("ops[0]: title must not be empty");
    expect(errorOf([{ op: "add", calendar: "Work", title: "x", start: "tomorrow" }])).toMatch(/start must be "YYYY-MM-DDTHH:MM" or "YYYY-MM-DD"/);
    expect(errorOf([{ op: "add", calendar: "Work", title: "x", start: "2026-11-02T25:00" }])).toMatch(/start must be/);
    expect(errorOf([{ op: "add", calendar: "Work", title: "x", start: "2026-11-02", allDay: false }])).toMatch(/a timed event needs start/);
    expect(errorOf([{ op: "add", calendar: "Work", title: "x", start: "2026-11-02T10:00", end: "2026-11-02T09:00" }])).toBe(
      "ops[0]: end must not be before start",
    );
    expect(errorOf([{ op: "add", calendar: "Work", title: "x", start: "2026-11-02", end: "2026-11-01" }])).toMatch(/end must not be before start/);
    expect(errorOf([{ op: "add", calendar: "Work", title: "x", start: "2026-11-02T10:00", end: "2026-11-03" }])).toMatch(/end of a timed event/);
    expect(errorOf([{ op: "add", calendar: "Work", title: "x", start: "2026-11-02", rrule: "FREQ=HOURLY" }])).toMatch(/^ops\[0\]: rrule:/);
    expect(errorOf([{ op: "update", id: "E1" }])).toMatch(/changes nothing/);
    expect(errorOf([{ op: "update", id: "E1", calendar: "Family" }])).toMatch(/changes nothing/);
    expect(errorOf([{ op: "update", id: "E3", allDay: false }])).toMatch(/give start "YYYY-MM-DDTHH:MM"/);
    expect(errorOf([{ op: "update", id: "E2", span: "all", title: "x" }])).toMatch(/span must be "this" or "future"/);
    expect(errorOf([{ op: "move", id: "E1" }])).toBe("ops[0]: op must be add, update or delete");
    const twice = { ...snapshot(), calendars: [...snapshot().calendars, { id: "C-work2", title: "work", writable: true }] };
    expect(errorOf([{ op: "add", calendar: "Work", title: "x", start: "2026-11-02" }], twice)).toMatch(/Several calendars are called "Work"/);
  });

  it("sum an edit up for the card", () => {
    const sum = (ops: unknown[], lang: "en" | "de" = "en") => calendarEditSummary(resolveCalendarOps(snapshot(), ops), lang);
    expect(sum([{ op: "add", calendar: "Family", title: "Dentist", start: "2026-11-05T09:00" }])).toBe("Add “Dentist” to Family");
    expect(sum([{ op: "add", calendar: "Family", title: "Zahnarzt", start: "2026-11-05T09:00" }], "de")).toBe("„Zahnarzt“ zu Family hinzufügen");
    const two = ["A", "B"].map((title) => ({ op: "add", calendar: "Work", title, start: "2026-11-05" }));
    expect(sum(two)).toBe("Add 2 events to Work");
    expect(sum(two, "de")).toBe("2 Termine zu Work hinzufügen");
    const mixed = [{ op: "update", id: "E1", title: "x" }, { op: "update", id: "E3", title: "y" }, { op: "delete", id: "E2" }];
    expect(sum(mixed)).toBe("Change 2 events, delete 1 event");
    expect(sum(mixed, "de")).toBe("2 Termine ändern, 1 Termin löschen");
    expect(sum([{ op: "delete", id: "E1" }])).toBe("Delete “Dentist”");
    expect(sum([{ op: "update", id: "E1", title: "Dentist (Dr. B)" }], "de")).toBe("„Dentist“ ändern");
  });

  it("edit_apple_calendar gives the resolved change to wait for, not a result", async () => {
    const t = await setup(false);
    const res = await runTool(
      "edit_apple_calendar",
      JSON.stringify({ ops: [{ op: "delete", id: "E1" }] }),
      toolCtx(t),
      new Set(Object.keys(TOOLS)),
    );
    expect(res).toMatchObject({
      ok: true,
      result: { waiting: true },
      appleCalendar: { summary: "Delete “Dentist”", ops: [{ op: "delete", id: "E1", calendar: "C-fam" }] },
    });
    const bad = await runTool("edit_apple_calendar", JSON.stringify({ ops: [{ op: "delete", id: "nope" }] }), toolCtx(t), new Set(Object.keys(TOOLS)));
    expect(bad.ok).toBe(false);
    expect(bad.appleCalendar).toBeUndefined();
  });
});

describe("an Apple Calendar edit in a chat", () => {
  async function chatWith(t: AssistantTest, text: string, extra: Record<string, unknown> = { appleCalendar: CALENDAR }) {
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
    const id = await chatWith(t, "schedule Dentist at 2026-11-05T09:00");
    expect(net.aiBody.messages[0].content).toMatch(/get_apple_calendar reads them; edit_apple_calendar changes them/);
    let list = await items(t, id);
    const edit = list.at(-1);
    expect(edit).toEqual({
      kind: "calendar",
      id: expect.any(String),
      summary: "Add “Dentist” to Family",
      ops: [{ op: "add", calendar: "C-fam", calendarTitle: "Family", title: "Dentist", start: "2026-11-05T09:00", end: "2026-11-05T10:00", allDay: false }],
    });
    expect(list.some((it) => it.kind === "tool")).toBe(false);
    // Only the waiting edit can be answered, and only on its own route.
    expect((await t.call("POST", `${t.ai}/chats/${id}/calendar`, { id: "nope", applied: false, ...CONTEXT })).status).toBe(409);
    expect((await t.call("POST", `${t.ai}/chats/${id}/reminders`, { id: edit.id, applied: false, ...CONTEXT })).status).toBe(409);
    expect((await t.call("POST", `${t.ai}/chats/${id}/answer`, { id: edit.id, selected: ["x"], ...CONTEXT })).status).toBe(409);
    expect((await t.call("POST", `${t.ai}/chats/${id}/calendar`, { id: edit.id, applied: true, ...CONTEXT })).status).toBe(400);

    const fresh = {
      ...CALENDAR,
      events: [...CALENDAR.events, { id: "E9", calendar: "C-fam", title: "Dentist", allDay: false, start: "2026-11-05T09:00", end: "2026-11-05T10:00" }],
    };
    const res = await t.call("POST", `${t.ai}/chats/${id}/calendar`, {
      id: edit.id,
      applied: true,
      results: [{ ok: true, id: "E9", extra: "dropped" }],
      appleCalendar: fresh,
      ...CONTEXT,
    });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    list = await items(t, id);
    expect(list.find((it) => it.kind === "calendar").answer).toEqual({ applied: true, results: [{ ok: true, id: "E9" }] });
    expect(list.at(-1)).toEqual({ kind: "assistant", text: "Done: 1 of 1 calendar changes applied." });
    expect(JSON.parse(String((await toolMessage(t, id, edit.id))?.content))).toEqual({
      applied: true,
      results: [{ op: "add", title: "Dentist", ok: true, id: "E9" }],
    });
    const row = (await t.store.getChat(id))!;
    expect((row.context as { appleCalendar: { events: unknown[] } }).appleCalendar.events).toHaveLength(6);
    expect((await t.call("POST", `${t.ai}/chats/${id}/calendar`, { id: edit.id, applied: false, ...CONTEXT })).status).toBe(409);
  });

  it("tells the model when the user declined, and what failed", async () => {
    const t = await setup();
    await configure(t);
    const id = await chatWith(t, "cancel event E2@2026-11-12");
    let edit = (await items(t, id)).at(-1);
    expect(edit).toMatchObject({ kind: "calendar", summary: "Delete “Standup”", ops: [{ op: "delete", span: "future" }] });
    await t.call("POST", `${t.ai}/chats/${id}/calendar`, { id: edit.id, applied: false, appleCalendar: CALENDAR, ...CONTEXT });
    let list = await items(t, id);
    expect(list.find((it) => it.id === edit.id).answer).toEqual({ applied: false });
    expect(list.at(-1).text).toBe("OK, I left your calendars as they were.");
    expect(JSON.parse(String((await toolMessage(t, id, edit.id))?.content))).toEqual({
      applied: false,
      note: "The user declined these changes: nothing was changed in their calendars.",
    });

    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "cancel event E1", ...CONTEXT, appleCalendar: CALENDAR });
    edit = (await items(t, id)).at(-1);
    await t.call("POST", `${t.ai}/chats/${id}/calendar`, {
      id: edit.id,
      applied: true,
      results: [{ ok: false, error: "The event is gone" }],
      appleCalendar: CALENDAR,
      ...CONTEXT,
    });
    list = await items(t, id);
    expect(list.find((it) => it.id === edit.id).answer).toEqual({ applied: true, results: [{ ok: false, error: "The event is gone" }] });
    expect(list.at(-1).text).toBe("Done: 0 of 1 calendar changes applied.");
    expect(JSON.parse(String((await toolMessage(t, id, edit.id))?.content))).toEqual({
      applied: true,
      results: [{ op: "delete", title: "Dentist", ok: false, error: "The event is gone" }],
    });
  });

  it("is skipped by a new message, and errors go back to the model", async () => {
    const t = await setup();
    await configure(t);
    const id = await chatWith(t, "schedule Offsite at 2026-11-10 in Work");
    const edit = (await items(t, id)).at(-1);
    expect(edit.ops[0]).toMatchObject({ calendar: "C-work", allDay: true, end: "2026-11-10" });
    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "never mind", ...CONTEXT, appleCalendar: CALENDAR });
    const list = await items(t, id);
    expect(list.find((it) => it.id === edit.id).skipped).toBe(true);
    expect(JSON.parse(String((await toolMessage(t, id, edit.id))?.content))).toMatchObject({
      skipped: true,
      note: expect.stringMatching(/nothing was changed in their calendars/),
    });
    expect((await t.call("POST", `${t.ai}/chats/${id}/calendar`, { id: edit.id, applied: true, results: [], ...CONTEXT })).status).toBe(409);

    await t.call("POST", `${t.ai}/chats/${id}/messages`, { text: "cancel event H1", ...CONTEXT, appleCalendar: CALENDAR });
    const after = await items(t, id);
    expect(after.filter((it) => it.kind === "calendar")).toHaveLength(1);
    expect(after.at(-1).text).toMatch(/^That didn't work: ops\[0\]: The calendar “Holidays” is read-only/);
  });

  it("reads the calendars, and isn't offered to viewers or without them", async () => {
    const t = await setup();
    await configure(t);
    const id = await chatWith(t, "my calendars");
    expect((await items(t, id)).at(-1).text).toBe("You have 5 events in 3 calendars.");

    const res = await t.view("POST", `${t.ai}/chats`, { text: "my calendars", ...CONTEXT, appleCalendar: CALENDAR });
    expect(res.status).toBe(200);
    let sent = (net.aiBody.tools ?? []).map((x: { function: { name: string } }) => x.function.name);
    expect(sent).toContain("get_apple_calendar");
    expect(sent).not.toContain("edit_apple_calendar");

    await chatWith(t, "hello", {});
    sent = (net.aiBody.tools ?? []).map((x: { function: { name: string } }) => x.function.name);
    expect(sent).not.toContain("get_apple_calendar");
    expect(sent).not.toContain("edit_apple_calendar");
    expect(net.aiBody.messages[0].content).toMatch(/device calendars aren't available in this chat/);
  });

  it("comes along with an imported chat, checked", async () => {
    const t = await setup();
    const res = await t.call("POST", `${t.ai}/chats/import`, {
      title: "Old",
      items: [
        { kind: "user", text: "add the dentist" },
        {
          kind: "calendar",
          id: "c1",
          summary: "Add “Dentist” to Family",
          ops: [{ op: "add", calendar: "C-fam", calendarTitle: "Family", title: "Dentist", start: "2026-11-05", end: "2026-11-05", allDay: true }, 7],
          answer: { applied: false },
        },
        { kind: "calendar", id: "c2", summary: "Delete “Dentist”", ops: [] },
      ],
      history: [],
    });
    expect(res.status, JSON.stringify(res.data)).toBe(201);
    const got = (await t.call("GET", `${t.ai}/chats/${res.data.chat.id}`)).data.items;
    expect(got[1]).toEqual({
      kind: "calendar",
      id: "c1",
      summary: "Add “Dentist” to Family",
      ops: [{ op: "add", calendar: "C-fam", calendarTitle: "Family", title: "Dentist", start: "2026-11-05", end: "2026-11-05", allDay: true }],
      answer: { applied: false },
    });
    expect(got[2]).toMatchObject({ kind: "calendar", id: "c2", skipped: true });
  });
});
