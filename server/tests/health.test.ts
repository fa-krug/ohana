// Check-ups and vaccinations (lib/health, /families/{id}/health…): the schedule's dates, each
// item's state from the birthday and the records, the routes and who may do what, the
// "everything earlier was done" shortcut, what happens to a member's records when a person accepts
// their invite or a member leaves, and the module turned off.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createFamilyApi } from "@/lib/api/family-api";
import { handleDisabledModules } from "@/lib/api/disabled-modules";
import { createToken } from "@/lib/auth/tokens";
import type { Db } from "@/lib/db";
import { healthRecords } from "@/lib/db/schema";
import { createInvite, acceptInvite } from "@/lib/families/invites";
import { removeMember, setMemberBirthday } from "@/lib/families/members";
import { addPerson } from "@/lib/families/people";
import { handleHealth } from "@/lib/health/routes";
import { SCHEDULE, SCHEDULE_BY_CODE, addAge, itemsFor, seasonOf } from "@/lib/health/schedule";
import { type HealthRecord, personHealth } from "@/lib/health/status";
import type { AiEnv } from "@/lib/assistant/routes";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";
import { jsonRequest } from "@/lib/test/http";

const BASE = "http://ohana.test/api/v1";
const TODAY = "2026-11-02";
const MIA = "2025-02-10"; // 20 months: U7 open, U7a next
const ANNA = "1960-03-15"; // 66
const BEN = "1990-06-01";

let db: Db;
let annaId: string;
let benId: string;
let familyId: string;
let miaId: string;

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Res = { status: number; data: any };

function call(userId: string) {
  const env = { store: { getAiSettings: async () => null } } as unknown as AiEnv;
  const handler = createFamilyApi([handleDisabledModules, handleHealth(env)], { db, appUrl: "http://ohana.test", now: () => NOW });
  const token = createToken(db, { userId, kind: "api" }, NOW).token;
  return async (method: string, path: string, body?: unknown): Promise<Res> => {
    const sep = path.includes("?") ? "&" : "?";
    const res = await handler(jsonRequest(`${BASE}/families/${familyId}${path}${sep}today=${TODAY}&lang=en`, method, token, body));
    return { status: res.status, data: await res.json() };
  };
}

const rec = (code: string, day: string | null, extra: Partial<HealthRecord> = {}): HealthRecord => ({
  id: `${code}-${day}`,
  code,
  day,
  status: "done",
  note: "",
  recorded: TODAY,
  ...extra,
});

const state = (birthday: string, records: HealthRecord[], today = TODAY) =>
  Object.fromEntries(personHealth(birthday, today, records, "en").items.map((i) => [i.code, i]));

beforeEach(() => {
  db = createTestDb();
  annaId = makeUser(db, { name: "Anna" }).id;
  benId = makeUser(db, { name: "Ben" }).id;
  familyId = makeFamily(db, annaId, [{ userId: benId, role: "viewer" }]).id;
  setMemberBirthday(db, { id: annaId }, familyId, annaId, ANNA, NOW);
  setMemberBirthday(db, { id: benId }, familyId, benId, BEN, NOW);
  miaId = addPerson(db, { id: annaId }, familyId, { name: "Mia", birthday: MIA }, NOW).person.id;
});

afterEach(() => {
  delete process.env.DISABLED_MODULES;
});

describe("the schedule", () => {
  it("adds ages to a day, a missing month end on the month's last day", () => {
    expect(addAge("2025-01-31", { m: 1 })).toBe("2025-02-28");
    expect(addAge("2024-02-29", { y: 1 })).toBe("2025-02-28");
    expect(addAge("2025-02-10", { m: 20 })).toBe("2026-10-10");
    expect(addAge("2025-02-10", { m: 4, d: 15 })).toBe("2025-06-25");
    expect(addAge("2025-12-30", { w: 1 })).toBe("2026-01-06");
  });

  it("has unique codes, windows in order and both languages", () => {
    expect(new Set(SCHEDULE.map((i) => i.code)).size).toBe(SCHEDULE.length);
    for (const i of SCHEDULE) {
      const born = "2020-01-31";
      expect(addAge(born, i.from) <= addAge(born, i.to), i.code).toBe(true);
      expect(addAge(born, i.to) <= addAge(born, i.until), i.code).toBe(true);
      expect(i.title.en && i.title.de && i.detail.en && i.detail.de, i.code).toBeTruthy();
      if (i.after) expect(SCHEDULE_BY_CODE.has(i.after)).toBe(true);
    }
  });

  it("gives children their items until 18, adults theirs by age", () => {
    const codes = (b: string) => itemsFor(b, TODAY).map((i) => i.code);
    expect(codes(MIA)).toContain("u7");
    expect(codes(MIA)).not.toContain("td");
    expect(codes(BEN)).toEqual(["td"]);
    expect(codes(ANNA)).toEqual(["td", "flu", "covid", "pneumo", "shingles-1", "shingles-2"]);
    expect(codes("1950-01-01")).toContain("rsv");
    expect(codes("2008-11-03")).toContain("j2");
    expect(codes("2008-11-02")).toEqual(["td"]);
    expect(codes("2027-01-01")).toEqual([]);
  });

  it("knows the autumn season", () => {
    expect(seasonOf("2026-11-02")).toEqual({ start: "2026-10-01", counts: "2026-08-01", end: "2027-03-31" });
    expect(seasonOf("2027-02-01").start).toBe("2026-10-01");
    expect(seasonOf("2027-06-01").start).toBe("2027-10-01");
  });
});

describe("the states", () => {
  it("are past, due or upcoming by the windows, done or skipped by the records", () => {
    const s = state(MIA, [rec("u6", "2026-01-12"), rec("vac-11m", null, { status: "skipped" })]);
    expect(s.u5.status).toBe("past");
    expect(s.u6.status).toBe("done");
    expect(s.u6.records).toEqual([{ id: "u6-2026-01-12", day: "2026-01-12", status: "done", note: "" }]);
    expect(s["vac-11m"].status).toBe("skipped");
    expect(s.u7).toMatchObject({ status: "due", from: "2026-10-10", to: "2027-02-10", until: "2027-05-10", kind: "checkup" });
    expect(s["vac-15m"]).toMatchObject({ status: "due", vaccines: ["MMR (2)", "Chickenpox (2)"] });
    expect(s.u7a).toMatchObject({ status: "upcoming", from: "2027-11-10" });
    expect(s.u10.notAlwaysPaid).toBe(true);
  });

  it("names next the open window closing first, else the next to open", () => {
    const h = personHealth(MIA, TODAY, [], "de");
    expect(h.next).toMatchObject({ code: "vac-12m", title: "Impfungen mit 12 Monaten" });
    expect(h.counts.due).toBe(3); // vac-12m, vac-15m, u7
    const all = h.items.filter((i) => i.status === "due").map((i) => rec(i.code, TODAY));
    expect(personHealth(MIA, TODAY, all, "en").next).toMatchObject({ code: "u7a", status: "upcoming" });
    expect(personHealth(null, TODAY, [], "en")).toEqual({ items: [], next: null, counts: { due: 0, past: 0, unknown: 0 } });
  });

  it("repeats tetanus every 10 years: unknown, then done until it's due again", () => {
    expect(state(BEN, []).td).toMatchObject({ status: "unknown", from: null, repeats: true });
    expect(state(BEN, [rec("td", "2019-05-03")]).td).toMatchObject({ status: "done", from: "2029-05-03" });
    expect(state(BEN, [rec("td", "2016-05-03"), rec("td", "2009-01-01")]).td).toMatchObject({ status: "due", from: "2026-05-03" });
    // A shot without a date counts from the day it was recorded.
    expect(state(BEN, [rec("td", null, { recorded: "2026-01-01" })]).td).toMatchObject({ status: "done", from: "2036-01-01" });
  });

  it("asks for flu and COVID-19 each autumn", () => {
    expect(state(ANNA, []).flu).toMatchObject({ status: "due", from: "2026-10-01", until: "2027-03-31" });
    expect(state(ANNA, [rec("flu", "2026-10-20")]).flu.status).toBe("done");
    expect(state(ANNA, [rec("flu", "2025-10-20")]).flu.status).toBe("due");
    expect(state(ANNA, [rec("flu", "2025-10-20")], "2026-06-01").flu).toMatchObject({ status: "upcoming", from: "2026-10-01" });
    expect(state(ANNA, [rec("flu", "2025-10-20")], "2026-02-01").flu.status).toBe("done");
  });

  it("times a second dose from the first", () => {
    expect(state(ANNA, [])["shingles-2"]).toMatchObject({ status: "upcoming", from: null });
    expect(state(ANNA, [rec("shingles-1", "2026-10-01")])["shingles-2"]).toMatchObject({ status: "upcoming", from: "2026-12-01", until: "2027-04-01" });
    expect(state(ANNA, [rec("shingles-1", "2025-01-01")])["shingles-2"].status).toBe("due");
    expect(state(ANNA, [rec("shingles-1", null)])["shingles-2"].status).toBe("unknown");
    expect(state("2015-01-01", [rec("hpv-1", "2025-01-01")])["hpv-2"]).toMatchObject({ status: "past", until: "2026-02-01" });
  });
});

describe("/health", () => {
  it("lists everyone to editors and a viewer only themselves", async () => {
    const res = await call(annaId)("GET", "/health");
    expect(res.status).toBe(200);
    expect(res.data).toMatchObject({ canEdit: true, scan: false, asOf: expect.stringContaining("STIKO") });
    expect(res.data.members.map((m: { name: string }) => m.name)).toEqual(["Anna", "Ben", "Mia"]);
    const mia = res.data.members.find((m: { id: string }) => m.id === miaId);
    expect(mia).toMatchObject({ birthday: MIA, account: false, canEdit: true, next: { code: "vac-12m" } });
    expect(mia.items.find((i: { code: string }) => i.code === "u7")).toMatchObject({ title: "U7", status: "due" });

    const own = await call(benId)("GET", "/health");
    expect(own.data.canEdit).toBe(false);
    expect(own.data.members.map((m: { id: string }) => m.id)).toEqual([benId]);
  });

  it("records, replaces a once-only item, adds a repeating one, changes and deletes", async () => {
    const anna = call(annaId);
    const first = await anna("POST", "/health/records", { memberId: miaId, records: [{ code: "u7", day: "2026-10-20", note: " Dr. Weiß " }] });
    expect(first.status).toBe(201);
    expect(first.data.records).toEqual([{ id: expect.any(String), memberId: miaId, code: "u7", day: "2026-10-20", status: "done", note: "Dr. Weiß" }]);
    expect(first.data.replaced).toEqual([]);
    expect(first.data.member.items.find((i: { code: string }) => i.code === "u7").status).toBe("done");

    const again = await anna("POST", "/health/records", { memberId: miaId, records: [{ code: "u7", day: "2026-10-21" }] });
    expect(again.data.replaced).toEqual([first.data.records[0]]);

    await anna("POST", "/health/records", { memberId: annaId, records: [{ code: "td", day: "2019-05-03" }] });
    const td = await anna("POST", "/health/records", { memberId: annaId, records: [{ code: "td", day: "2009-05-03" }, { code: "td", day: "2009-05-03" }] });
    expect(td.data.records).toHaveLength(1);
    expect(td.data.replaced).toEqual([]);
    expect(td.data.member.items.find((i: { code: string }) => i.code === "td").records.map((r: { day: string }) => r.day)).toEqual(["2019-05-03", "2009-05-03"]);

    const id = again.data.records[0].id;
    const changed = await anna("PATCH", `/health/records/${id}`, { status: "skipped", day: null });
    expect(changed.data.record).toMatchObject({ id, status: "skipped", day: null });
    expect(changed.data.member.items.find((i: { code: string }) => i.code === "u7").status).toBe("skipped");
    const deleted = await anna("DELETE", `/health/records/${id}`);
    expect(deleted.data.deleted).toBe(id);
    expect(deleted.data.member.items.find((i: { code: string }) => i.code === "u7").status).toBe("due");
    expect((await anna("DELETE", `/health/records/${id}`)).status).toBe(404);
  });

  it("checks the records", async () => {
    const anna = call(annaId);
    const post = (records: unknown[], memberId = miaId) => anna("POST", "/health/records", { memberId, records });
    expect((await post([{ code: "u99" }])).status).toBe(400);
    expect((await post([{ code: "u7", day: "2026-11-03" }])).data.error).toBe("day can't be in the future");
    expect((await post([{ code: "u1", day: "2025-02-09" }])).data.error).toBe("day can't be before the birthday");
    expect((await post([{ code: "u7", status: "maybe" }])).status).toBe(400);
    expect((await post([])).status).toBe(400);
    expect((await post([{ code: "u7" }], "nobody")).status).toBe(404);
    expect((await post([{ code: "u7" }])).data.records[0].day).toBeNull();
    expect((await anna("GET", "/health/nothing")).status).toBe(404);
    expect((await anna("PUT", "/health")).status).toBe(405);
  });

  it("lets a viewer record only their own", async () => {
    const ben = call(benId);
    expect((await ben("POST", "/health/records", { memberId: miaId, records: [{ code: "u7" }] })).status).toBe(404);
    const own = await ben("POST", "/health/records", { memberId: benId, records: [{ code: "td", day: "2020-01-01" }] });
    expect(own.status).toBe(201);
    const mia = await call(annaId)("POST", "/health/records", { memberId: miaId, records: [{ code: "u7" }] });
    expect((await ben("DELETE", `/health/records/${mia.data.records[0].id}`)).status).toBe(404);
    expect((await ben("PATCH", `/health/records/${own.data.records[0].id}`, { note: "Boostrix" })).data.record.note).toBe("Boostrix");
  });

  it("marks every closed window done at once, date unknown", async () => {
    const res = await call(annaId)("POST", "/health/past", { memberId: miaId });
    expect(res.status).toBe(200);
    expect(res.data.records.map((r: { code: string }) => r.code).sort()).toEqual(
      ["rsv-infant", "u1", "u2", "u3", "u4", "u5", "u6", "vac-11m", "vac-2m", "vac-4m", "vac-6w"].sort(),
    );
    expect(res.data.records.every((r: { day: null }) => r.day === null)).toBe(true);
    expect(res.data.member.counts).toEqual({ due: 3, past: 0, unknown: 0 });
    expect((await call(annaId)("POST", "/health/past", { memberId: miaId })).data.records).toEqual([]);
  });

  it("has no items without a birthday", async () => {
    const leo = addPerson(db, { id: annaId }, familyId, { name: "Leo" }, NOW).person;
    const res = await call(annaId)("GET", "/health");
    expect(res.data.members.find((m: { id: string }) => m.id === leo.id)).toMatchObject({ birthday: null, items: [], next: null });
    const scan = await call(annaId)("POST", "/health/scan", { memberId: leo.id, pages: ["/9j/"] });
    expect(scan.status).toBe(409);
  });

  it("moves a person's records to the account that accepts their invite, and deletes a leaving member's", async () => {
    const anna = call(annaId);
    await anna("POST", "/health/records", { memberId: miaId, records: [{ code: "u7", day: "2026-10-20" }] });
    const invite = createInvite(db, { id: annaId }, familyId, "viewer", NOW, miaId);
    const miaUser = makeUser(db, { name: "" }).id;
    acceptInvite(db, miaUser, invite.code, NOW);
    const rows = db.select().from(healthRecords).all();
    expect(rows).toEqual([expect.objectContaining({ memberUserId: miaUser, memberPersonId: null, code: "u7" })]);
    const res = await anna("GET", "/health");
    expect(res.data.members.find((m: { id: string }) => m.id === miaUser).items.find((i: { code: string }) => i.code === "u7").status).toBe("done");

    removeMember(db, { id: annaId }, familyId, miaUser);
    expect(db.select().from(healthRecords).all()).toEqual([]);
  });

  it("answers 404 with the module off", async () => {
    process.env.DISABLED_MODULES = "health";
    expect((await call(annaId)("GET", "/health")).status).toBe(404);
  });
});
