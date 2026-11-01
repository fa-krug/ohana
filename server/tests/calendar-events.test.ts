// Events over several days and repeating events (lib/calendar/events.ts): occurrences in the
// family API, the calendar, the overview and the search; series, overrides and exdates; the
// "this", "future" and "all" changes; and the migration that brought them.

import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import Database from "better-sqlite3";
import { eq, isNotNull } from "drizzle-orm";
import { drizzle } from "drizzle-orm/better-sqlite3";
import { migrate } from "drizzle-orm/better-sqlite3/migrator";
import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import * as schema from "@/lib/db/schema";
import { calEntryTypes, calEvents, families } from "@/lib/db/schema";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { handleFamily } from "@/lib/calendar/family-routes";
import { handleCalendar } from "@/lib/calendar/vacation";
import { findExternalEvent, handleEvents } from "@/lib/calendar/events";
import { familyDashboard } from "@/lib/families/dashboard";
import { searchFamily } from "@/lib/families/search";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const BASE = "http://ohana.test/api/v1";

let db: Db;
let editorId: string;
let viewerId: string;
let familyId: string;

beforeEach(() => {
  db = createTestDb();
  editorId = makeUser(db).id;
  viewerId = makeUser(db).id;
  familyId = makeFamily(db, editorId, [{ userId: viewerId, role: "viewer" }]).id;
});

function call(userId: string) {
  const handler = createFamilyApi([handleFamily, handleCalendar, handleEvents], { db, appUrl: "http://ohana.test", now: () => NOW });
  const token = createToken(db, { userId, kind: "api" }, NOW).token;
  return async (method: string, path: string, body?: unknown) => {
    const res = await handler(
      new Request(BASE + path, {
        method,
        headers: { authorization: `Bearer ${token}`, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
        body: body !== undefined ? JSON.stringify(body) : undefined,
      }),
    );
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return { status: res.status, data: (await res.json()) as any };
  };
}

const ev = (path = "") => `/families/${familyId}/events${path}`;
type Occ = { id: string; occurrence: string | null; date: string; endDate: string; title: string; start: string | null };
/** Occurrences from..to as [date, occurrence, title]. */
async function shown(from: string, to: string) {
  const res = await call(editorId)("GET", ev(`?from=${from}&to=${to}`));
  expect(res.status, JSON.stringify(res.data)).toBe(200);
  return (res.data.events as Occ[]).map((e) => [e.date, e.occurrence, e.title]);
}

const swimming = {
  date: "2026-11-02", // a Monday
  start: "17:00",
  end: "18:00",
  title: "Swimming",
  rrule: "FREQ=WEEKLY",
};

describe("events over several days", () => {
  it("show on every day they cover, in ranges they overlap", async () => {
    const edit = call(editorId);
    const ski = await edit("POST", ev(), { date: "2026-12-30", endDate: "2027-01-02", title: "Ski trip" });
    expect(ski.status).toBe(201);
    expect(ski.data).toMatchObject({ date: "2026-12-30", endDate: "2027-01-02", rrule: null, exdates: [], overrides: [] });

    expect(await shown("2027-01-01", "2027-01-31")).toEqual([["2026-12-30", null, "Ski trip"]]);
    expect(await shown("2026-12-01", "2026-12-29")).toEqual([]);
    expect(await shown("2027-01-03", "2027-01-31")).toEqual([]);

    const y2026 = (await edit("GET", `/families/${familyId}?year=2026`)).data.events;
    expect(Object.keys(y2026)).toEqual(["2026-12-30", "2026-12-31"]);
    expect(y2026["2026-12-31"][0]).toMatchObject({ id: ski.data.id, date: "2026-12-30", endDate: "2027-01-02", occurrence: null });
    const y2027 = (await edit("GET", `/families/${familyId}?year=2027`)).data.events;
    expect(Object.keys(y2027)).toEqual(["2027-01-01", "2027-01-02"]);
  });

  it("may end at an earlier time on a later day; checks the days and times", async () => {
    const post = (body: unknown) => call(editorId)("POST", ev(), body);
    const night = await post({ date: "2026-11-05", endDate: "2026-11-06", start: "18:00", end: "09:00", title: "Night train" });
    expect(night.status).toBe(201);
    expect(night.data).toMatchObject({ start: "18:00", end: "09:00", endDate: "2026-11-06" });
    expect((await post({ date: "2026-11-05", start: "18:00", end: "09:00", title: "x" })).data.error).toBe("end must be after start");
    expect((await post({ date: "2026-11-05", endDate: "2026-11-04", title: "x" })).data.error).toBe("endDate must not be before date");
    expect((await post({ date: "2026-11-05", endDate: "2026-11-31", title: "x" })).status).toBe(400);
    // endDate defaults to date.
    expect((await post({ date: "2026-11-05", title: "One day" })).data.endDate).toBe("2026-11-05");
  });

  it("GET /events needs a range of at most 3 years", async () => {
    const edit = call(editorId);
    expect((await edit("GET", ev())).status).toBe(400);
    expect((await edit("GET", ev("?from=2026-01-01"))).status).toBe(400);
    expect((await edit("GET", ev("?from=2026-01-01&to=2030-01-01"))).status).toBe(400);
    expect((await edit("GET", ev("?from=2026-02-01&to=2026-01-01"))).status).toBe(400);
    expect((await edit("GET", ev("?from=2026-01-01&to=2028-12-31"))).status).toBe(200);
    expect((await edit("GET", ev("?year=2026"))).status).toBe(200);
  });
});

describe("repeating events", () => {
  it("check the rule, the exdates and the overrides", async () => {
    const post = (body: unknown) => call(editorId)("POST", ev(), body);
    const bad = await post({ ...swimming, rrule: "FREQ=SOMETIMES" });
    expect(bad.status).toBe(400);
    expect(bad.data.error).toMatch(/^rrule: /);
    expect((await post({ ...swimming, rrule: "FREQ=DAILY;COUNT=2;UNTIL=20270101" })).status).toBe(400);
    expect((await post({ ...swimming, rrule: "FREQ=WEEKLY;BYDAY=1MO" })).status).toBe(400);
    expect((await post({ ...swimming, rrule: 7 })).status).toBe(400);
    expect((await post({ ...swimming, exdates: "2026-11-09" })).status).toBe(400);
    expect((await post({ ...swimming, exdates: ["2026-02-30"] })).status).toBe(400);
    expect((await post({ ...swimming, overrides: [{ occurrence: "soon", date: "2026-11-09", title: "x" }] })).status).toBe(400);
    expect((await post({ ...swimming, overrides: [{ occurrence: "2026-11-09", date: "2026-11-09" }] })).status).toBe(400);
    const twice = { occurrence: "2026-11-09", date: "2026-11-09", title: "x" };
    expect((await post({ ...swimming, overrides: [twice, twice] })).status).toBe(400);
    expect((await post({ ...swimming, overrides: {} })).status).toBe(400);

    const ok = await post({ ...swimming, rrule: " freq=weekly;byday=mo " });
    expect(ok.status).toBe(201);
    expect(ok.data.rrule).toBe("FREQ=WEEKLY;BYDAY=MO");
  });

  it("expand with exdates and overrides, also one moved to another day", async () => {
    const { data } = await call(editorId)("POST", ev(), {
      ...swimming,
      exdates: ["2026-11-16"],
      overrides: [{ occurrence: "2026-11-09", date: "2026-11-10", start: "18:00", end: "19:00", title: "Swimming (Tue)" }],
    });
    expect(await shown("2026-11-01", "2026-11-30")).toEqual([
      ["2026-11-02", "2026-11-02", "Swimming"],
      ["2026-11-10", "2026-11-09", "Swimming (Tue)"],
      ["2026-11-23", "2026-11-23", "Swimming"],
      ["2026-11-30", "2026-11-30", "Swimming"],
    ]);
    // The moved occurrence is where it went, not where it was.
    expect(await shown("2026-11-10", "2026-11-10")).toEqual([["2026-11-10", "2026-11-09", "Swimming (Tue)"]]);
    expect(await shown("2026-11-09", "2026-11-09")).toEqual([]);
    const all = (await call(editorId)("GET", ev("?from=2026-11-01&to=2026-11-30"))).data.events as Occ[];
    expect(all.every((e) => e.id === data.id)).toBe(true);
    expect(all[1]).toMatchObject({ start: "18:00", rrule: "FREQ=WEEKLY", source: "manual" });
    // It started in November: nothing before.
    expect(await shown("2026-10-01", "2026-10-31")).toEqual([]);
  });

  it("drop overrides of exdates and of days that aren't occurrences", async () => {
    const { data } = await call(editorId)("POST", ev(), {
      ...swimming,
      exdates: ["2026-11-16", "2026-11-16"],
      overrides: [
        { occurrence: "2026-11-16", date: "2026-11-16", title: "gone" },
        { occurrence: "2026-11-17", date: "2026-11-17", title: "no Monday" },
        { occurrence: "2026-11-23", date: "2026-11-23", title: "kept" },
      ],
    });
    expect(data.exdates).toEqual(["2026-11-16"]);
    expect(data.overrides.map((o: { title: string }) => o.title)).toEqual(["kept"]);
  });

  it("end after COUNT occurrences or on UNTIL; monthly by weekday ordinals", async () => {
    const post = (body: unknown) => call(editorId)("POST", ev(), body);
    await post({ date: "2026-11-27", title: "Last Friday", rrule: "FREQ=MONTHLY;BYDAY=-1FR;COUNT=3" });
    expect(await shown("2026-11-01", "2027-12-31")).toEqual([
      ["2026-11-27", "2026-11-27", "Last Friday"],
      ["2026-12-25", "2026-12-25", "Last Friday"],
      ["2027-01-29", "2027-01-29", "Last Friday"],
    ]);
    await post({ date: "2026-11-09", title: "Council", rrule: "FREQ=MONTHLY;BYDAY=2MO" });
    await post({ date: "2026-11-02", title: "Camp", rrule: "FREQ=DAILY;UNTIL=20261104" });
    expect(await shown("2026-11-01", "2027-01-31").then((l) => l.filter((e) => e[2] !== "Last Friday"))).toEqual([
      ["2026-11-02", "2026-11-02", "Camp"],
      ["2026-11-03", "2026-11-03", "Camp"],
      ["2026-11-04", "2026-11-04", "Camp"],
      ["2026-11-09", "2026-11-09", "Council"],
      ["2026-12-14", "2026-12-14", "Council"],
      ["2027-01-11", "2027-01-11", "Council"],
    ]);
  });

  it("sort by date, all-day first, then by start", async () => {
    const post = (body: unknown) => call(editorId)("POST", ev(), body);
    await post({ date: "2026-11-02", start: "09:00", title: "B", rrule: "FREQ=DAILY;COUNT=2" });
    await post({ date: "2026-11-02", start: "08:00", title: "A" });
    await post({ date: "2026-11-03", title: "All day" });
    expect(await shown("2026-11-01", "2026-11-30")).toEqual([
      ["2026-11-02", null, "A"],
      ["2026-11-02", "2026-11-02", "B"],
      ["2026-11-03", null, "All day"],
      ["2026-11-03", "2026-11-03", "B"],
    ]);
  });
});

describe("the calendar, the overview and the search", () => {
  it("list every occurrence on every day it covers", async () => {
    const post = (body: unknown) => call(editorId)("POST", ev(), body);
    // Friday to Sunday, every week.
    const weekend = await post({ date: "2026-11-06", endDate: "2026-11-08", title: "Grandma's", rrule: "FREQ=WEEKLY;COUNT=3" });
    await post({ date: "2026-10-01", start: "07:00", title: "Walk the dog", rrule: "FREQ=DAILY" });
    await post({ date: "2026-11-09", title: "Dentist" });

    const state = (await call(viewerId)("GET", `/families/${familyId}?year=2026`)).data.events;
    const titles = (day: string) => (state[day] ?? []).map((e: Occ) => e.title);
    expect(titles("2026-11-07")).toEqual(["Grandma's", "Walk the dog"]);
    expect(titles("2026-11-08")).toEqual(["Grandma's", "Walk the dog"]);
    expect(titles("2026-11-14")).toEqual(["Grandma's", "Walk the dog"]);
    expect(titles("2026-11-28")).toEqual(["Walk the dog"]);
    expect(titles("2026-09-30")).toEqual([]);
    expect(titles("2026-12-31")).toEqual(["Walk the dog"]);
    expect(state["2026-11-14"][0]).toMatchObject({ id: weekend.data.id, occurrence: "2026-11-13", date: "2026-11-13", endDate: "2026-11-15" });

    const d = await familyDashboard(db, familyId, "2026-11-07");
    expect(d.todayEvents.map((e) => [e.title, e.occurrence])).toEqual([
      ["Grandma's", "2026-11-06"],
      ["Walk the dog", "2026-11-07"],
    ]);
    expect(d.tomorrowEvents.map((e) => [e.title, e.occurrence])).toEqual([
      ["Grandma's", "2026-11-06"],
      ["Walk the dog", "2026-11-08"],
    ]);
    const coming = d.upcoming.flatMap((u) => (u.kind === "event" ? [[u.date, u.event.title]] : []));
    expect(coming.slice(0, 4)).toEqual([
      ["2026-11-08", "Walk the dog"],
      ["2026-11-09", "Dentist"],
      ["2026-11-09", "Walk the dog"],
      ["2026-11-10", "Walk the dog"],
    ]);
  });

  it("find a series once, at its next occurrence, else its last", async () => {
    const post = (body: unknown) => call(editorId)("POST", ev(), body);
    const piano = await post({ date: "2026-01-05", start: "15:00", title: "Piano lesson", rrule: "FREQ=WEEKLY", exdates: ["2026-11-02"] });
    const over = await post({ date: "2026-01-05", title: "Piano course", rrule: "FREQ=WEEKLY;COUNT=3" });
    const hits = searchFamily(db, familyId, editorId, "piano", { today: "2026-11-01" }).results;
    expect(hits.map((h) => [h.id, h.day, h.time])).toEqual([
      [piano.data.id, "2026-11-09", "15:00"],
      [over.data.id, "2026-01-19", null],
    ]);
  });
});

describe("changing a series", () => {
  async function series(body: Record<string, unknown> = {}) {
    const res = await call(editorId)("POST", ev(), { ...swimming, ...body });
    expect(res.status, JSON.stringify(res.data)).toBe(201);
    return res.data;
  }
  const patch = (id: string, query: string, body: unknown, userId = editorId) =>
    call(userId)("PATCH", ev(`/${id}${query}`), body);
  const get = async (id: string) => (await call(editorId)("GET", ev(`/${id}`))).data;

  it("all: a new date moves every occurrence, its exdates and its overrides", async () => {
    const s = await series({
      endDate: "2026-11-03",
      exdates: ["2026-11-16"],
      overrides: [{ occurrence: "2026-11-09", date: "2026-11-10", endDate: "2026-11-11", title: "Moved" }],
    });
    const res = await patch(s.id, "", { date: "2026-11-03", title: "Swim club" });
    expect(res.status).toBe(200);
    expect(res.data).toMatchObject({
      id: s.id,
      date: "2026-11-03",
      endDate: "2026-11-04",
      title: "Swim club",
      rrule: "FREQ=WEEKLY",
      exdates: ["2026-11-17"],
      overrides: [{ occurrence: "2026-11-10", date: "2026-11-11", endDate: "2026-11-12", title: "Moved" }],
    });
    expect(await shown("2026-11-01", "2026-11-30")).toEqual([
      ["2026-11-03", "2026-11-03", "Swim club"],
      ["2026-11-11", "2026-11-10", "Moved"],
      ["2026-11-24", "2026-11-24", "Swim club"],
    ]);
    // ?span=all is the same; occurrence is then ignored.
    expect((await patch(s.id, "?occurrence=2026-11-24&span=all", { note: "Bring goggles" })).data).toMatchObject({ note: "Bring goggles", date: "2026-11-03" });
  });

  it("all: exdates and overrides in the body replace them; rrule null makes it a single event", async () => {
    const s = await series({ exdates: ["2026-11-16"] });
    const res = await patch(s.id, "", { exdates: ["2026-11-23"], overrides: [{ occurrence: "2026-11-30", date: "2026-11-30", title: "Last" }] });
    expect(res.data).toMatchObject({ exdates: ["2026-11-23"], overrides: [{ occurrence: "2026-11-30", title: "Last" }] });
    expect((await patch(s.id, "", { exdates: ["nope"] })).status).toBe(400);
    expect((await patch(s.id, "", { rrule: "FREQ=WEEKLY;BYDAY=SO" })).status).toBe(400);
    const once = await patch(s.id, "", { rrule: null });
    expect(once.data).toMatchObject({ rrule: null, exdates: [], overrides: [] });
    expect(await shown("2026-11-01", "2026-11-30")).toEqual([["2026-11-02", null, "Swimming"]]);
    expect(db.select().from(calEvents).where(isNotNull(calEvents.seriesId)).all()).toEqual([]);
  });

  it("this: creates the occurrence's override, then changes it", async () => {
    const s = await series({ exdates: ["2026-11-23"] });
    const first = await patch(s.id, "?occurrence=2026-11-09&span=this", { start: "16:00", rrule: null, exdates: [] });
    expect(first.status).toBe(200);
    expect(first.data).toMatchObject({ id: s.id, rrule: "FREQ=WEEKLY", exdates: ["2026-11-23"] });
    expect(first.data.overrides).toEqual([
      { occurrence: "2026-11-09", date: "2026-11-09", endDate: "2026-11-09", start: "16:00", end: "18:00", title: "Swimming", location: "", person: "", note: "", url: "" },
    ]);
    // Without span it is "this" too; the override keeps what it had.
    const second = await patch(s.id, "?occurrence=2026-11-09", { title: "Swim gala", date: "2026-11-10" });
    expect(second.data.overrides).toEqual([
      expect.objectContaining({ occurrence: "2026-11-09", date: "2026-11-10", endDate: "2026-11-10", start: "16:00", title: "Swim gala" }),
    ]);
    expect(await shown("2026-11-09", "2026-11-10")).toEqual([["2026-11-10", "2026-11-09", "Swim gala"]]);
    // The series itself is unchanged.
    expect(await get(s.id)).toMatchObject({ date: "2026-11-02", start: "17:00", title: "Swimming" });
  });

  it("this / future: refuses what isn't an occurrence, a single event and bad parameters", async () => {
    const s = await series({ exdates: ["2026-11-23"] });
    expect((await patch(s.id, "?occurrence=2026-11-03&span=this", { title: "x" })).status).toBe(404);
    expect((await patch(s.id, "?occurrence=2026-11-23&span=this", { title: "x" })).status).toBe(404);
    expect((await patch(s.id, "?occurrence=2026-10-26&span=future", { title: "x" })).status).toBe(404);
    expect((await patch(s.id, "?occurrence=2026-11-09&span=sometimes", { title: "x" })).status).toBe(400);
    expect((await patch(s.id, "?span=this", { title: "x" })).status).toBe(400);
    expect((await patch(s.id, "?occurrence=9.11.&span=this", { title: "x" })).status).toBe(400);
    expect((await patch(s.id, "?occurrence=2026-11-09&span=this", { title: " " })).status).toBe(400);
    const single = (await call(editorId)("POST", ev(), { date: "2026-11-05", title: "Once" })).data;
    expect((await patch(single.id, "?occurrence=2026-11-05&span=this", { title: "x" })).status).toBe(400);
    expect((await patch("nope", "?occurrence=2026-11-05&span=this", { title: "x" })).status).toBe(404);
  });

  it("future: splits the series, the new one takes over the rest of COUNT, the exdates and the overrides", async () => {
    // Mondays 2, 9, 16, 23 (taken out), 30 Nov and 7 Dec.
    const s = await series({
      rrule: "FREQ=WEEKLY;BYDAY=MO;COUNT=6",
      exdates: ["2026-11-23"],
      overrides: [
        { occurrence: "2026-11-09", date: "2026-11-09", title: "Early" },
        { occurrence: "2026-11-30", date: "2026-11-30", title: "Late" },
      ],
    });
    const res = await patch(s.id, "?occurrence=2026-11-16&span=future", { start: "18:00", end: "19:00" });
    expect(res.status).toBe(201);
    expect(res.data.id).not.toBe(s.id);
    expect(res.data).toMatchObject({
      date: "2026-11-16",
      start: "18:00",
      end: "19:00",
      title: "Swimming",
      rrule: "FREQ=WEEKLY;BYDAY=MO;COUNT=4",
      exdates: ["2026-11-23"],
      overrides: [expect.objectContaining({ occurrence: "2026-11-30", title: "Late" })],
    });
    expect(await get(s.id)).toMatchObject({
      rrule: "FREQ=WEEKLY;BYDAY=MO;UNTIL=20261115",
      exdates: [],
      overrides: [expect.objectContaining({ occurrence: "2026-11-09", title: "Early" })],
    });
    const list = (await call(editorId)("GET", ev("?from=2026-11-01&to=2027-03-31"))).data.events as Occ[];
    expect(list.map((e) => [e.date, e.id === s.id ? "old" : "new", e.title, e.start])).toEqual([
      ["2026-11-02", "old", "Swimming", "17:00"],
      ["2026-11-09", "old", "Early", null],
      ["2026-11-16", "new", "Swimming", "18:00"],
      ["2026-11-30", "new", "Late", null],
      ["2026-12-07", "new", "Swimming", "18:00"],
    ]);
  });

  it("future: a new first day moves the following exdates and overrides along; the first occurrence means all", async () => {
    const s = await series({
      rrule: "FREQ=WEEKLY;UNTIL=20261231",
      exdates: ["2026-11-23"],
      overrides: [{ occurrence: "2026-11-30", date: "2026-11-30", title: "Late" }],
    });
    const split = await patch(s.id, "?occurrence=2026-11-16&span=future", { date: "2026-11-17" });
    expect(split.status).toBe(201);
    expect(split.data).toMatchObject({
      date: "2026-11-17",
      rrule: "FREQ=WEEKLY;UNTIL=20261231",
      exdates: ["2026-11-24"],
      overrides: [expect.objectContaining({ occurrence: "2026-12-01", date: "2026-12-01", title: "Late" })],
    });
    // The body's rrule makes the new series repeat differently.
    const again = await patch(split.data.id, "?occurrence=2026-12-08&span=future", { rrule: "FREQ=DAILY;COUNT=2" });
    expect(again.data).toMatchObject({ date: "2026-12-08", rrule: "FREQ=DAILY;COUNT=2" });

    const first = await patch(s.id, "?occurrence=2026-11-02&span=future", { title: "From the start" });
    expect(first.status).toBe(200);
    expect(first.data).toMatchObject({ id: s.id, title: "From the start", rrule: "FREQ=WEEKLY;UNTIL=20261115" });
  });

  it("future: an override of the occurrence is where the new series starts from", async () => {
    const s = await series({ overrides: [{ occurrence: "2026-11-16", date: "2026-11-16", start: "08:00", title: "Morning" }] });
    const res = await patch(s.id, "?occurrence=2026-11-16&span=future", { title: "Morning swim" });
    expect(res.data).toMatchObject({ date: "2026-11-16", start: "08:00", end: null, title: "Morning swim", overrides: [] });
  });

  it("delete this, future and all", async () => {
    const s = await series({ overrides: [{ occurrence: "2026-11-09", date: "2026-11-10", title: "Moved" }] });
    const del = (query: string, userId = editorId) => call(userId)("DELETE", ev(`/${s.id}${query}`));

    expect((await del("?occurrence=2026-11-09&span=this", viewerId)).status).toBe(403);
    const one = await del("?occurrence=2026-11-09&span=this");
    expect(one.status).toBe(200);
    expect(one.data).toMatchObject({ id: s.id, exdates: ["2026-11-09"], overrides: [] });
    expect((await del("?occurrence=2026-11-09&span=this")).status).toBe(404);

    const rest = await del("?occurrence=2026-11-23&span=future");
    expect(rest.data).toMatchObject({ rrule: "FREQ=WEEKLY;UNTIL=20261122", exdates: ["2026-11-09"] });
    expect(await shown("2026-11-01", "2027-12-31")).toEqual([
      ["2026-11-02", "2026-11-02", "Swimming"],
      ["2026-11-16", "2026-11-16", "Swimming"],
    ]);

    expect((await del("?occurrence=2026-11-02&span=future")).data).toEqual({ deleted: s.id });
    expect((await call(editorId)("GET", ev(`/${s.id}`))).status).toBe(404);

    const t = await series({ overrides: [{ occurrence: "2026-11-09", date: "2026-11-09", title: "x" }] });
    expect((await call(editorId)("DELETE", ev(`/${t.id}`))).data).toEqual({ deleted: t.id });
    expect(db.select().from(calEvents).all()).toEqual([]);
    const single = (await call(editorId)("POST", ev(), { date: "2026-11-05", title: "Once" })).data;
    expect((await call(editorId)("DELETE", ev(`/${single.id}?occurrence=2026-11-05&span=this`))).status).toBe(400);
  });
});

describe("series as they are stored", () => {
  it("GET /events?raw=1 and /events/{id} answer whole series; override rows are no events of their own", async () => {
    const edit = call(editorId);
    const s = (await edit("POST", ev(), { ...swimming, overrides: [{ occurrence: "2026-11-09", date: "2026-11-09", title: "x" }] })).data;
    const once = (await edit("POST", ev(), { date: "2025-03-01", title: "Long ago" })).data;
    const raw = await call(viewerId)("GET", ev("?raw=1"));
    expect(raw.status).toBe(200);
    expect(raw.data.events).toEqual([once, s]);
    expect((await call(viewerId)("GET", ev(`/${s.id}`))).data).toEqual(s);
    const overrideRow = db.select().from(calEvents).where(isNotNull(calEvents.seriesId)).get()!;
    expect((await edit("GET", ev(`/${overrideRow.id}`))).status).toBe(404);
    expect((await edit("PATCH", ev(`/${overrideRow.id}`), { title: "y" })).status).toBe(404);
    expect((await edit("DELETE", ev(`/${overrideRow.id}`))).status).toBe(404);
    expect((await edit("GET", ev("/nope"))).status).toBe(404);
  });

  it("viewers read; other families' members get nothing", async () => {
    const s = (await call(editorId)("POST", ev(), swimming)).data;
    const view = call(viewerId);
    expect((await view("GET", ev("?year=2026"))).status).toBe(200);
    expect((await view("POST", ev(), swimming)).status).toBe(403);
    expect((await view("PATCH", ev(`/${s.id}`), { title: "x" })).status).toBe(403);
    expect((await view("PATCH", ev(`/${s.id}?occurrence=2026-11-09&span=this`), { title: "x" })).status).toBe(403);
    expect((await view("PATCH", ev(`/${s.id}?occurrence=2026-11-09&span=future`), { title: "x" })).status).toBe(403);
    expect((await view("DELETE", ev(`/${s.id}`))).status).toBe(403);
    const stranger = makeUser(db).id;
    for (const path of ["?raw=1", "?year=2026", `/${s.id}`]) expect((await call(stranger)("GET", ev(path))).status).toBe(404);
  });

  it("an Apple Calendar series is imported once; its overrides don't count as imports", async () => {
    const edit = call(editorId);
    const body = { ...swimming, externalId: "EK-9" };
    const first = await edit("POST", ev(), body);
    expect(first.status).toBe(201);
    expect(first.data).toMatchObject({ source: "apple", externalId: "EK-9", rrule: "FREQ=WEEKLY" });
    await edit("PATCH", ev(`/${first.data.id}?occurrence=2026-11-09&span=this`), { title: "Changed" });
    const again = await edit("POST", ev(), body);
    expect(again.status).toBe(200);
    expect(again.data.id).toBe(first.data.id);
    expect(again.data.overrides).toHaveLength(1);
    expect(findExternalEvent(db, familyId, "EK-9")?.id).toBe(first.data.id);
    // Occurrences carry the series' link.
    expect((await edit("GET", ev("?from=2026-11-09&to=2026-11-09"))).data.events[0]).toMatchObject({ source: "apple", externalId: "EK-9", title: "Changed" });
    // Splitting keeps the link with the old series; the new one is the family's own.
    const split = await edit("PATCH", ev(`/${first.data.id}?occurrence=2026-11-16&span=future`), { title: "New" });
    expect(split.data).toMatchObject({ source: "manual", externalId: null });
    expect(findExternalEvent(db, familyId, "EK-9")?.id).toBe(first.data.id);
  });
});

describe("the migration", () => {
  it("keeps every event as a one-day event and drops the feed ids without touching the families", () => {
    const dir = mkdtempSync(join(tmpdir(), "ohana-migrations-"));
    try {
      const src = resolve(__dirname, "../drizzle");
      cpSync(src, dir, { recursive: true });
      const journalPath = join(dir, "meta/_journal.json");
      const journal = JSON.parse(readFileSync(journalPath, "utf8")) as { entries: { tag: string }[] };
      const idx = journal.entries.findIndex((e) => e.tag.endsWith("_events_series"));
      expect(idx).toBeGreaterThan(0);
      writeFileSync(journalPath, JSON.stringify({ ...journal, entries: journal.entries.slice(0, idx) }));

      const sqlite = new Database(":memory:");
      sqlite.pragma("foreign_keys = ON");
      const old = drizzle(sqlite, { schema });
      migrate(old, { migrationsFolder: dir });
      sqlite.prepare("insert into families (id, name, feed_id, legacy_id, created_at, updated_at) values ('f1', 'A', 'feedf1', 'legacy1', 0, 0)").run();
      sqlite.prepare("insert into cal_entry_types (family_id, year, id, name, color, role, position) values ('f1', 2026, 'vacation', 'Vacation', '#22c55e', 'covers', 0)").run();
      sqlite
        .prepare("insert into cal_events (id, family_id, day, start, \"end\", title, source, created_at) values ('e1', 'f1', '2026-11-03', '10:30', '11:00', 'Dr. Berg', 'appointment', 0)")
        .run();
      migrate(old, { migrationsFolder: src });

      expect(old.select().from(families).all()).toEqual([expect.objectContaining({ id: "f1", name: "A" })]);
      expect(old.select().from(families).get()).not.toHaveProperty("feedId");
      expect(old.select().from(calEntryTypes).all()).toHaveLength(1);
      expect(old.select().from(calEvents).where(eq(calEvents.id, "e1")).get()).toMatchObject({
        day: "2026-11-03",
        endDay: "2026-11-03",
        start: "10:30",
        end: "11:00",
        rrule: null,
        exdates: "[]",
        seriesId: null,
        occurrence: null,
        source: "appointment",
      });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
