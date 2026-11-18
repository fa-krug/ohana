// Check-ups and vaccinations, part two: the worker's reminders (lib/health/notify.ts: a window
// that opens, a check-up's window closing, once each, only the editors' devices, from the hour
// on, nothing with the module off), reading a booklet's pages with the family's AI (POST
// /health/scan, the mock AI) and the assistant's tools with their undo.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { runTool, TOOLS, toolsFor } from "@/lib/assistant/tools";
import type { Db } from "@/lib/db";
import { healthRecords } from "@/lib/db/schema";
import { setMemberBirthday } from "@/lib/families/members";
import { addPerson } from "@/lib/families/people";
import { healthNotifications, noticesFor, recipientsFor } from "@/lib/health/notify";
import { scanPages } from "@/lib/health/scan";
import type { ItemState } from "@/lib/health/status";
import { type AssistantTest, assistantTest, configure, toolContext } from "@/lib/test/assistant";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";
import { type FakePush, fakePush } from "@/lib/test/push";

afterEach(() => {
  delete process.env.DISABLED_MODULES;
});

const item = (over: Partial<ItemState>): ItemState => ({
  code: "u7",
  kind: "checkup",
  title: "U7",
  detail: "",
  vaccines: [],
  notAlwaysPaid: false,
  status: "due",
  from: "2026-10-10",
  to: "2027-02-10",
  until: "2027-05-10",
  repeats: false,
  optional: false,
  records: [],
  ...over,
});

describe("noticesFor", () => {
  it("tells a window that opened in the last two weeks, and a check-up's closing one", () => {
    expect(noticesFor(item({}), "2026-10-10")).toEqual([{ kind: "open", key: "u7:2026-10-10:open" }]);
    expect(noticesFor(item({}), "2026-10-24")).toHaveLength(1);
    expect(noticesFor(item({}), "2026-10-25")).toEqual([]);
    expect(noticesFor(item({}), "2027-04-12")).toEqual([{ kind: "closing", key: "u7:2026-10-10:closing" }]);
    expect(noticesFor(item({}), "2027-05-11")).toEqual([]);
    expect(noticesFor(item({ kind: "vaccination" }), "2027-04-12")).toEqual([]);
    expect(noticesFor(item({ status: "done" }), "2026-10-10")).toEqual([]);
    // Flu before 60: optional, never told about.
    expect(noticesFor(item({ code: "flu", status: "optional", optional: true, from: "2026-10-01" }), "2026-10-02")).toEqual([]);
    // A short window: its opening message says until when.
    expect(noticesFor(item({ from: "2026-10-01", until: "2026-11-05" }), "2026-10-20")).toEqual([]);
    expect(noticesFor(item({ code: "td", from: "2026-11-01", until: null, to: null }), "2026-11-02")).toEqual([
      { kind: "open", key: "td:2026-11-01:open" },
    ]);
  });
});

describe("healthNotifications", () => {
  let db: Db;
  let annaId: string;
  let benId: string;
  let familyId: string;
  let push: FakePush;
  const at = (day: string, hour = 9) => {
    const [y, m, d] = day.split("-").map(Number);
    return new Date(y, m - 1, d, hour);
  };

  beforeEach(() => {
    db = createTestDb();
    annaId = makeUser(db, { name: "Anna" }).id;
    benId = makeUser(db, { name: "Ben" }).id;
    familyId = makeFamily(db, annaId, [{ userId: benId, role: "viewer" }]).id;
    push = fakePush(db);
    push.device(annaId, 1);
    push.device(benId, 2);
  });

  it("pushes an opening window to the editors, once, from the hour on", async () => {
    const mia = addPerson(db, { id: annaId }, familyId, { name: "Mia", birthday: "2025-02-10" }, NOW).person;
    expect(await healthNotifications(db, at("2026-10-12", 6), { push: push.client, hour: 7 })).toEqual([]);
    const told = await healthNotifications(db, at("2026-10-12"), { push: push.client, hour: 7 });
    expect(told).toEqual([{ familyId, memberId: mia.id, code: "u7", kind: "open", userIds: [annaId] }]);
    expect(push.received(2)).toEqual([]);
    expect(push.received(1)).toEqual([
      expect.objectContaining({ title: "U7 for Mia", body: "Due until 10 May 2027", path: `/f/${familyId}/health/${mia.id}` }),
    ]);
    expect(await healthNotifications(db, at("2026-10-13"), { push: push.client, hour: 7 })).toEqual([]);
    // Closing in four weeks, still not recorded.
    expect(await healthNotifications(db, at("2027-04-12"), { push: push.client, hour: 7 })).toEqual([
      expect.objectContaining({ code: "u7", kind: "closing" }),
    ]);
    expect(push.received(1).at(-1)?.body).toBe("Only until 10 May 2027: time to book");
  });

  it("says nothing about a recorded one, and nothing with the module off", async () => {
    const mia = addPerson(db, { id: annaId }, familyId, { name: "Mia", birthday: "2025-02-10" }, NOW).person;
    db.insert(healthRecords)
      .values({ id: "r1", familyId, memberPersonId: mia.id, code: "u7", day: "2026-10-11", status: "done", createdAt: NOW, updatedAt: NOW })
      .run();
    expect(await healthNotifications(db, at("2026-10-12"), { push: push.client, hour: 7 })).toEqual([]);
    setMemberBirthday(db, { id: annaId }, familyId, annaId, "1960-03-15", NOW);
    process.env.DISABLED_MODULES = "health";
    expect(await healthNotifications(db, at("2026-10-02"), { push: push.client, hour: 7 })).toEqual([]);
    delete process.env.DISABLED_MODULES;
    // Flu and COVID-19 from 1 October; Ben's (36) are optional: only his regular flu shot is
    // told about.
    setMemberBirthday(db, { id: benId }, familyId, benId, "1990-06-01", NOW);
    db.insert(healthRecords)
      .values({ id: "r2", familyId, memberUserId: benId, code: "flu", day: "2025-10-15", status: "done", createdAt: NOW, updatedAt: NOW })
      .run();
    const told = await healthNotifications(db, at("2026-10-02"), { push: push.client, hour: 7 });
    // Grown-ups get their own, nobody else: Ben (a viewer) his, Anna (the editor) only hers.
    expect(told.map((n) => [n.code, n.memberId, n.userIds])).toEqual([
      ["flu", annaId, [annaId]],
      ["covid", annaId, [annaId]],
      ["flu", benId, [benId]],
    ]);
    expect(push.received(1).map((p) => p.title)).toEqual(["Flu for Anna", "COVID-19 for Anna"]);
    expect(push.received(2).map((p) => p.title)).toEqual(["Flu for Ben"]);
  });

  it("tells grown-ups themselves, children and people without an account the editors", () => {
    const today = "2026-11-02";
    const editors = ["anna"];
    expect(recipientsFor({ id: "ben", account: true, birthday: "2008-11-02" }, editors, today)).toEqual(["ben"]);
    expect(recipientsFor({ id: "anna", account: true, birthday: "1980-01-01" }, editors, today)).toEqual(["anna"]);
    // A child's own account and the editors.
    expect(recipientsFor({ id: "tom", account: true, birthday: "2008-11-03" }, editors, today)).toEqual(["anna", "tom"]);
    expect(recipientsFor({ id: "mia", account: false, birthday: "1950-01-01" }, editors, today)).toEqual(["anna"]);
    expect(recipientsFor({ id: "mia", account: false, birthday: "2020-01-01" }, [], today)).toEqual([]);
  });
});

describe("POST /health/scan and the tools", () => {
  let current: AssistantTest[] = [];
  afterEach(async () => {
    await Promise.all(current.map((t) => t.stop()));
    current = [];
  });
  const TODAY = "2026-11-02";
  const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]).toString("base64");

  function setup() {
    const t = assistantTest({ worker: false });
    current.push(t);
    const mia = addPerson(t.db, { id: t.editor.id }, t.familyId, { name: "Mia", birthday: "2025-02-10" }, NOW).person;
    setMemberBirthday(t.db, { id: t.editor.id }, t.familyId, t.editor.id, "1985-04-01", NOW);
    const ctx = toolContext(t, TODAY);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const tool = async (name: string, args: unknown, c = ctx): Promise<any> => runTool(name, JSON.stringify(args), c, new Set(Object.keys(TOOLS)));
    const undo = async (change: { undo: { method: string; path: string; body?: unknown }[] }) => {
      for (const step of change.undo) {
        const res = await t.call(step.method, `${t.f}${step.path}?today=${TODAY}`, step.body);
        expect(res.status, JSON.stringify(res.data)).toBeLessThan(300);
      }
    };
    return { t, mia, ctx, tool, undo, scan: (body: unknown) => t.call("POST", `${t.f}/health/scan?today=${TODAY}&lang=en`, body) };
  }

  it("checks the pages", () => {
    expect(() => scanPages([])).toThrow("pages must be a list");
    expect(() => scanPages(["aGVsbG8="])).toThrow("JPEG or PNG");
    expect(() => scanPages(Array(9).fill(JPEG))).toThrow("At most 8 pages");
    expect(scanPages([JPEG])).toHaveLength(1);
  });

  it("answers ai: false without the family's AI, and reads the booklet with it", async () => {
    const { t, mia, scan } = setup();
    expect((await t.call("GET", `${t.f}/health`)).data.scan).toBe(false);
    expect((await scan({ memberId: mia.id, pages: [JPEG] })).data).toEqual({ ai: false, items: [] });
    await configure(t);
    expect((await t.call("GET", `${t.f}/health`)).data.scan).toBe(true);
    await t.call("POST", `${t.f}/health/records?today=${TODAY}`, { memberId: mia.id, records: [{ code: "u1", day: "2025-02-10" }] });
    const res = await scan({ memberId: mia.id, pages: [JPEG] });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    // u99 is no code, td and flu aren't a child's; the second U2 is the same check-up; an
    // unreadable date stays a suggestion without one.
    expect(res.data).toEqual({
      ai: true,
      items: [
        { code: "vac-2m", title: "Vaccinations at 2 months", day: null, note: "Vaxelis", known: false },
        { code: "u1", title: "U1", day: "2025-02-10", note: "", known: true },
        { code: "u2", title: "U2", day: "2025-02-14", note: "Stempel Dr. Weiß", known: false },
      ],
    });
    // A grown-up's booklet: tetanus counts, the future flu shot doesn't.
    const own = await scan({ memberId: t.editor.id, pages: [JPEG] });
    expect(own.data.items).toEqual([{ code: "td", title: "Tetanus / diphtheria", day: "2019-05-03", note: "Boostrix", known: false }]);
    // A viewer only for themselves.
    expect((await t.view("POST", `${t.f}/health/scan`, { memberId: mia.id, pages: [JPEG] })).status).toBe(404);
  });

  it("let the assistant read, record and remove, and undo it", async () => {
    const { t, mia, ctx, tool, undo } = setup();
    const read = await tool("get_health", { member: "mia" });
    expect(read.ok).toBe(true);
    expect(read.result.members).toHaveLength(1);
    expect(read.result.members[0].next).toMatchObject({ code: "vac-12m", status: "due" });

    const first = await tool("record_health", { member: "Mia", records: [{ code: "u7", day: "2026-10-20" }] });
    expect(first.ok, JSON.stringify(first.result)).toBe(true);
    expect(first.change).toEqual({
      kind: "health",
      summary: "Recorded a check-up / vaccination for Mia",
      undo: [{ method: "DELETE", path: `/health/records/${first.result.records[0].id}` }],
    });
    const again = await tool("record_health", { member: mia.id, records: [{ code: "u7", day: "2026-10-22", note: "Dr. Weiß" }] });
    expect(again.change.undo).toEqual([
      { method: "DELETE", path: `/health/records/${again.result.records[0].id}` },
      { method: "POST", path: "/health/records", body: { memberId: mia.id, records: [{ id: first.result.records[0].id, code: "u7", day: "2026-10-20", status: "done", note: "" }] } },
    ]);
    await undo(again.change);
    expect(t.db.select().from(healthRecords).all()).toEqual([expect.objectContaining({ id: first.result.records[0].id, day: "2026-10-20" })]);

    const removed = await tool("remove_health_record", { id: first.result.records[0].id });
    expect(removed.change.summary).toBe("Removed a check-up / vaccination record of Mia");
    expect(t.db.select().from(healthRecords).all()).toEqual([]);
    await undo(removed.change);
    expect(t.db.select().from(healthRecords).all()).toHaveLength(1);

    expect((await tool("record_health", { member: "Nobody", records: [{ code: "u7" }] })).ok).toBe(false);
    expect((await tool("record_health", { member: "Mia", records: [{ code: "u7", day: "2030-01-01" }] })).result.error).toBe("day can't be in the future");

    // A viewer's chat sees and records only their own.
    const viewer = { ...ctx, userId: t.viewer.id };
    setMemberBirthday(t.db, { id: t.viewer.id }, t.familyId, t.viewer.id, "1990-01-01", NOW);
    expect((await tool("get_health", {}, viewer)).result.members.map((m: { id: string }) => m.id)).toEqual([t.viewer.id]);
    expect((await tool("record_health", { member: "Mia", records: [{ code: "u7" }] }, viewer)).ok).toBe(false);

    // Read-only chats get get_health only; with the module off, none.
    const names = (writes: boolean) => toolsFor({ writes, search: false }).map((s) => s.function.name).filter((n) => n.includes("health"));
    expect(names(false)).toEqual(["get_health"]);
    expect(names(true)).toEqual(["get_health", "record_health", "remove_health_record"]);
    process.env.DISABLED_MODULES = "health";
    expect(names(true)).toEqual([]);
  });
});
