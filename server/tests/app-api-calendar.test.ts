// Editing events (PATCH /events/{id}) and events the app imports from Apple Calendar.

import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { handleFamily } from "@/lib/calendar/family-routes";
import { handleCalendar } from "@/lib/calendar/vacation";
import { createEvent, handleEvents } from "@/lib/calendar/events";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const BASE = "http://ohana.test/api/v1";

let db: Db;
let editorId: string;
let viewerId: string;
let familyId: string;

function call(userId: string) {
  const handler = createFamilyApi([handleFamily, handleCalendar, handleEvents], {
    db,
    appUrl: "http://ohana.test",
    now: () => NOW,
  });
  const token = createToken(db, { userId, kind: "api" }, NOW).token;
  return async (method: string, path: string, body?: unknown) => {
    const res = await handler(
      new Request(BASE + path, {
        method,
        headers: {
          authorization: `Bearer ${token}`,
          ...(body !== undefined ? { "content-type": "application/json" } : {}),
        },
        body: body !== undefined ? JSON.stringify(body) : undefined,
      }),
    );
    return { status: res.status, data: await res.json() };
  };
}

beforeEach(() => {
  db = createTestDb();
  editorId = makeUser(db).id;
  viewerId = makeUser(db).id;
  familyId = makeFamily(db, editorId, [{ userId: viewerId, role: "viewer" }]).id;
});

describe("PATCH /events/{id}", () => {
  it("changes the given fields and keeps the others", async () => {
    const edit = call(editorId);
    const created = await edit("POST", `/families/${familyId}/events`, {
      date: "2026-11-03",
      start: "10:30",
      end: "11:00",
      title: "Dr. Berg",
      person: "Mia",
    });
    const id = created.data.id;
    const res = await edit("PATCH", `/families/${familyId}/events/${id}`, { title: "Dr. Brandt", date: "2026-11-04" });
    expect(res.status).toBe(200);
    expect(res.data).toMatchObject({
      id,
      date: "2026-11-04",
      start: "10:30",
      end: "11:00",
      title: "Dr. Brandt",
      person: "Mia",
      source: "manual",
    });
    const list = await edit("GET", `/families/${familyId}/events?year=2026`);
    const { exdates: _e, overrides: _o, ...occurrence } = res.data;
    expect(list.data.events).toEqual([{ ...occurrence, occurrence: null }]);
  });

  it("makes an event all-day with start null, which drops the end", async () => {
    const edit = call(editorId);
    const { data } = await edit("POST", `/families/${familyId}/events`, {
      date: "2026-11-03",
      start: "10:30",
      end: "11:00",
      title: "Trip",
    });
    const res = await edit("PATCH", `/families/${familyId}/events/${data.id}`, { start: null });
    expect(res.data).toMatchObject({ start: null, end: null });
  });

  it("keeps the source of a booked appointment", async () => {
    const e = createEvent(db, familyId, { date: "2026-11-03", title: "Dr. Berg" }, { source: "appointment", sourceId: "s1", sourceItem: "7" }, NOW);
    const res = await call(editorId)("PATCH", `/families/${familyId}/events/${e.id}`, { note: "Bring the card" });
    expect(res.data).toMatchObject({ source: "appointment", searchId: "s1", note: "Bring the card" });
  });

  it("checks the input, the role and the family", async () => {
    const edit = call(editorId);
    const { data } = await edit("POST", `/families/${familyId}/events`, { date: "2026-11-03", title: "x" });
    expect((await edit("PATCH", `/families/${familyId}/events/${data.id}`, { title: " " })).status).toBe(400);
    expect((await edit("PATCH", `/families/${familyId}/events/${data.id}`, { start: "11:00", end: "10:00" })).status).toBe(400);
    expect((await edit("PATCH", `/families/${familyId}/events/nope`, { title: "y" })).status).toBe(404);
    expect((await call(viewerId)("PATCH", `/families/${familyId}/events/${data.id}`, { title: "y" })).status).toBe(403);
    const other = makeFamily(db, viewerId).id;
    expect((await call(viewerId)("PATCH", `/families/${other}/events/${data.id}`, { title: "y" })).status).toBe(404);
  });
});

describe("POST /events with externalId (Apple Calendar)", () => {
  const apple = { date: "2026-11-05", start: "09:00", end: "10:00", title: "Swimming", externalId: " ABC-123:2026 " };

  it("saves the event as source apple with its externalId", async () => {
    const edit = call(editorId);
    const res = await edit("POST", `/families/${familyId}/events`, apple);
    expect(res.status).toBe(201);
    expect(res.data).toEqual({
      id: expect.any(String),
      date: "2026-11-05",
      endDate: "2026-11-05",
      start: "09:00",
      end: "10:00",
      title: "Swimming",
      location: "",
      person: "",
      note: "",
      url: "",
      source: "apple",
      searchId: null,
      externalId: "ABC-123:2026",
      rrule: null,
      exdates: [],
      overrides: [],
    });
    const list = await edit("GET", `/families/${familyId}/events?year=2026`);
    const { exdates: _e, overrides: _o, ...occurrence } = res.data;
    expect(list.data.events).toEqual([{ ...occurrence, occurrence: null }]);
  });

  it("answers the existing event for the same externalId instead of a second one", async () => {
    const edit = call(editorId);
    const first = await edit("POST", `/families/${familyId}/events`, apple);
    const again = await edit("POST", `/families/${familyId}/events`, { ...apple, title: "Swimming (moved)", externalId: "ABC-123:2026" });
    expect(again.status).toBe(200);
    expect(again.data).toEqual(first.data);
    const list = await edit("GET", `/families/${familyId}/events?year=2026`);
    expect(list.data.events).toHaveLength(1);
  });

  it("keeps families apart", async () => {
    const other = makeFamily(db, editorId).id;
    const edit = call(editorId);
    const a = await edit("POST", `/families/${familyId}/events`, apple);
    const b = await edit("POST", `/families/${other}/events`, apple);
    expect(b.status).toBe(201);
    expect(b.data.id).not.toBe(a.data.id);
    expect(b.data.externalId).toBe("ABC-123:2026");
  });

  it("refuses a bad externalId and one combined with a booking", async () => {
    const edit = call(editorId);
    for (const externalId of ["", "   ", "x".repeat(501), 42]) {
      expect((await edit("POST", `/families/${familyId}/events`, { ...apple, externalId })).status).toBe(400);
    }
    expect((await edit("POST", `/families/${familyId}/events`, { ...apple, searchId: "s1", resultId: 7 })).status).toBe(400);
    expect((await edit("POST", `/families/${familyId}/events`, { ...apple, externalId: "x".repeat(500) })).status).toBe(201);
    expect((await call(viewerId)("POST", `/families/${familyId}/events`, apple)).status).toBe(403);
  });

  it("leaves events without externalId as they were", async () => {
    const res = await call(editorId)("POST", `/families/${familyId}/events`, { date: "2026-11-05", title: "Dentist" });
    expect(res.status).toBe(201);
    expect(res.data).toMatchObject({ source: "manual", searchId: null, externalId: null });
  });

  it("keeps the source and externalId on PATCH", async () => {
    const edit = call(editorId);
    const { data } = await edit("POST", `/families/${familyId}/events`, apple);
    const res = await edit("PATCH", `/families/${familyId}/events/${data.id}`, { title: "Swim class", externalId: "other" });
    expect(res.status).toBe(200);
    expect(res.data).toMatchObject({ id: data.id, title: "Swim class", source: "apple", externalId: "ABC-123:2026" });
  });

  it("deletes an apple event like any other", async () => {
    const edit = call(editorId);
    const { data } = await edit("POST", `/families/${familyId}/events`, apple);
    expect((await edit("DELETE", `/families/${familyId}/events/${data.id}`)).status).toBe(200);
    expect((await edit("GET", `/families/${familyId}/events?year=2026`)).data.events).toEqual([]);
  });
});
