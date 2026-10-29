// Phase 7, Appointments → Calendar: booked slots become timed calendar events, which the REST
// API (/events), GET /families/{id} and the calendar feed (events=1) serve.

import { eq } from "drizzle-orm";
import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import { apptSearches, calEvents, familyMembers } from "@/lib/db/schema";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { AuthError } from "@/lib/auth/errors";
import { handleFamily } from "@/lib/calendar/family-routes";
import { handleCalendar } from "@/lib/calendar/vacation";
import { createEvent, findBooking, handleEvents, listBookedAppointments, listEvents } from "@/lib/calendar/events";
import { buildIcs } from "@/lib/calendar/ics";
import { bookSlot, removeBooking } from "@/lib/appointments/booking";
import { familyDashboard } from "@/lib/families/dashboard";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";
import { makeResult, makeRun, makeSearch } from "@/lib/test/appointments";

const BASE = "http://ohana.test/api/v1";

function api(db: Db) {
  const handler = createFamilyApi([handleFamily, handleCalendar, handleEvents], { db, appUrl: "http://ohana.test", now: () => NOW });
  return (token: string | null) =>
    async (method: string, path: string, body?: unknown) => {
      const res = await handler(
        new Request(BASE + path, {
          method,
          headers: {
            ...(token ? { authorization: `Bearer ${token}` } : {}),
            ...(body !== undefined ? { "content-type": "application/json" } : {}),
          },
          body: body !== undefined ? JSON.stringify(body) : undefined,
        }),
      );
      const text = await res.text();
      let data: any = text;
      try {
        data = JSON.parse(text);
      } catch {
        /* ics */
      }
      return { status: res.status, data };
    };
}

let db: Db;
let editorId: string;
let viewerId: string;
let familyId: string;
let feedId: string;

beforeEach(() => {
  db = createTestDb();
  editorId = makeUser(db).id;
  viewerId = makeUser(db).id;
  const f = makeFamily(db, editorId, [{ userId: viewerId, role: "viewer" }]);
  familyId = f.id;
  feedId = f.feedId;
});

const tokenOf = (userId: string) => createToken(db, { userId, kind: "api" }, NOW).token;

describe("events API", () => {
  it("adds, lists and deletes timed events; viewers only read", async () => {
    const call = api(db)(tokenOf(editorId));
    const view = api(db)(tokenOf(viewerId));
    const created = await call("POST", `/families/${familyId}/events`, {
      date: "2026-11-03",
      start: "10:30",
      end: "11:00",
      title: "Dr. Berg",
      location: "Praxis Berg, Hauptstr. 1",
      person: "Mia",
    });
    expect(created.status).toBe(201);
    expect(created.data).toMatchObject({ date: "2026-11-03", start: "10:30", end: "11:00", title: "Dr. Berg", source: "manual", searchId: null });

    const list = await view("GET", `/families/${familyId}/events?year=2026`);
    expect(list.status).toBe(200);
    expect(list.data.events.map((e: any) => e.title)).toEqual(["Dr. Berg"]);
    expect((await view("GET", `/families/${familyId}/events?from=2026-12-01&to=2026-12-31`)).data.events).toEqual([]);

    expect((await view("POST", `/families/${familyId}/events`, { date: "2026-11-04", title: "x" })).status).toBe(403);
    expect((await view("DELETE", `/families/${familyId}/events/${created.data.id}`)).status).toBe(403);

    // The calendar page gets them with the family, by day.
    const state = await view("GET", `/families/${familyId}?year=2026`);
    expect(state.data.events["2026-11-03"][0].title).toBe("Dr. Berg");

    expect((await call("DELETE", `/families/${familyId}/events/${created.data.id}`)).data).toEqual({ deleted: created.data.id });
    expect((await call("DELETE", `/families/${familyId}/events/${created.data.id}`)).status).toBe(404);
  });

  it("validates events", async () => {
    const call = api(db)(tokenOf(editorId));
    const post = (body: unknown) => call("POST", `/families/${familyId}/events`, body);
    expect((await post({ date: "2026-02-30", title: "x" })).status).toBe(400);
    expect((await post({ date: "2026-11-03", title: "  " })).status).toBe(400);
    expect((await post({ date: "2026-11-03", title: "x", start: "25:00" })).status).toBe(400);
    expect((await post({ date: "2026-11-03", title: "x", start: "10:00", end: "09:00" })).data.error).toBe("end must be after start");
    expect((await post({ date: "2026-11-03", title: "x", url: "javascript:alert(1)" })).status).toBe(400);
    // All day: no start, and an end without a start is dropped.
    const allDay = await post({ date: "2026-11-03", title: "Impfung" });
    expect(allDay.data).toMatchObject({ start: null, end: null });
  });

  it("hides another family's events", async () => {
    const other = makeFamily(db, makeUser(db).id);
    createEvent(db, other.id, { date: "2026-11-03", title: "secret" }, {}, NOW);
    const call = api(db)(tokenOf(editorId));
    expect((await call("GET", `/families/${other.id}/events`)).status).toBe(404);
    expect(listEvents(db, familyId)).toEqual([]);
  });
});

describe("calendar feed", () => {
  it("has timed events only with events=1", async () => {
    createEvent(db, familyId, { date: "2026-11-03", start: "10:30", title: "Dr. Berg", person: "Mia", location: "Praxis, Ort" }, {}, NOW);
    createEvent(db, familyId, { date: "2026-11-05", title: "Impfung" }, {}, NOW);
    const anon = api(db)(null);
    const plain = await anon("GET", `/families/${feedId}/calendar.ics`);
    expect(plain.data).not.toContain("Dr. Berg");
    const ics = (await anon("GET", `/families/${feedId}/calendar.ics?events=1`)).data as string;
    expect(ics).toContain("DTSTART:20261103T103000\r\n");
    expect(ics).toContain("DURATION:PT1H");
    expect(ics).toContain("SUMMARY:Dr. Berg (Mia)");
    expect(ics).toContain("LOCATION:Praxis\\, Ort");
    expect(ics).toContain("DTSTART;VALUE=DATE:20261105");
    expect(ics).toContain("DTEND;VALUE=DATE:20261106");
  });

  it("uses the end time when there is one", () => {
    const ics = buildIcs({
      calendarName: "x",
      uidPrefix: "p",
      types: [],
      entries: new Map(),
      events: [{ id: "e1", day: "2026-11-03", start: "08:15", end: "09:00", title: "T", location: "", person: "", note: "n", url: "https://a.test/" }],
      now: NOW,
    });
    expect(ics).toContain("UID:p-event-e1@ohana");
    expect(ics).toContain("DTEND:20261103T090000");
    expect(ics).toContain("URL:https://a.test/");
    expect(ics).toContain("DESCRIPTION:n\\nhttps://a.test/");
  });
});

describe("booking a slot", () => {
  function slot() {
    const search = makeSearch(db, familyId, { enabled: true, nextRunAt: NOW });
    const run = makeRun(db, search.id);
    const result = makeResult(db, run.id, {
      doctorName: "Dr. Berg",
      practiceName: "Praxis Berg",
      practiceAddress: "Hauptstr. 1",
      practiceZipcode: "10115",
      practiceCity: "Berlin",
      motiveLabel: "Erstuntersuchung",
      bookingUrl: "https://www.doctolib.de/berg",
    });
    return { search, result };
  }

  it("copies the slot into a calendar event and can stop the search", () => {
    const { search, result } = slot();
    const event = bookSlot(
      db,
      { id: editorId },
      familyId,
      search.id,
      result.id,
      { date: "2026-11-03", start: "10:30", person: "Mia", note: "Impfpass mitbringen", stopSearch: true },
      NOW,
    );
    expect(event).toMatchObject({
      day: "2026-11-03",
      start: "10:30",
      title: "Dr. Berg",
      location: "Praxis Berg, Hauptstr. 1, 10115 Berlin",
      person: "Mia",
      note: "Erstuntersuchung\nImpfpass mitbringen",
      url: "https://www.doctolib.de/berg",
      source: "appointment",
      sourceId: search.id,
      sourceItem: String(result.id),
    });
    expect(findBooking(db, familyId, search.id, result.id)?.id).toBe(event.id);
    const after = db.select().from(apptSearches).where(eq(apptSearches.id, search.id)).get()!;
    expect(after.enabled).toBe(false);
    expect(after.nextRunAt).toBeNull();
    expect(listBookedAppointments(db, familyId, "2026-11-01").map((e) => e.id)).toEqual([event.id]);
    expect(listBookedAppointments(db, familyId, "2026-11-04")).toEqual([]);
  });

  it("keeps the search running unless asked, and books a slot once", () => {
    const { search, result } = slot();
    bookSlot(db, { id: editorId }, familyId, search.id, result.id, { date: "2026-11-03", start: "10:30" }, NOW);
    expect(db.select().from(apptSearches).where(eq(apptSearches.id, search.id)).get()!.enabled).toBe(true);
    expect(() => bookSlot(db, { id: editorId }, familyId, search.id, result.id, { date: "2026-11-03", start: "10:30" }, NOW)).toThrow(
      expect.objectContaining({ status: 409 }),
    );
  });

  it("checks roles, the family and that the slot is the search's", () => {
    const { search, result } = slot();
    const input = { date: "2026-11-03", start: "10:30" };
    expect(() => bookSlot(db, { id: viewerId }, familyId, search.id, result.id, input, NOW)).toThrow(expect.objectContaining({ status: 403 }));
    const other = makeSearch(db, familyId);
    expect(() => bookSlot(db, { id: editorId }, familyId, other.id, result.id, input, NOW)).toThrow(expect.objectContaining({ status: 404 }));
    const stranger = makeUser(db);
    const theirs = makeFamily(db, stranger.id);
    expect(() => bookSlot(db, { id: stranger.id }, theirs.id, search.id, result.id, input, NOW)).toThrow(AuthError);
    expect(() => bookSlot(db, { id: editorId }, familyId, search.id, result.id, { date: "2026-11-03", start: "noon" }, NOW)).toThrow();
    expect(db.select().from(calEvents).all()).toEqual([]);
  });

  it("removes a booking (editors only), and the event outlives the results", () => {
    const { search, result } = slot();
    const event = bookSlot(db, { id: editorId }, familyId, search.id, result.id, { date: "2026-11-03", start: "10:30" }, NOW);
    expect(() => removeBooking(db, { id: viewerId }, familyId, event.id)).toThrow(expect.objectContaining({ status: 403 }));
    // Deleting the search (and its results) leaves the appointment in the calendar.
    db.delete(apptSearches).where(eq(apptSearches.id, search.id)).run();
    expect(listEvents(db, familyId)).toHaveLength(1);
    removeBooking(db, { id: editorId }, familyId, event.id);
    expect(listEvents(db, familyId)).toEqual([]);
    expect(() => removeBooking(db, { id: editorId }, familyId, event.id)).toThrow(expect.objectContaining({ status: 404 }));
  });

  it("shows booked appointments on the overview, today's and coming up", async () => {
    const { search, result } = slot();
    bookSlot(db, { id: editorId }, familyId, search.id, result.id, { date: "2026-11-01", start: "09:00", person: "Mia" }, NOW);
    createEvent(db, familyId, { date: "2026-11-10", start: "14:00", title: "Zahnarzt" }, {}, NOW);
    db.insert(familyMembers).values({ familyId, userId: makeUser(db).id, role: "viewer", joinedAt: NOW }).run();
    const d = await familyDashboard(db, familyId, "2026-11-01");
    expect(d.todayEvents.map((e) => e.title)).toEqual(["Dr. Berg"]);
    expect(d.upcoming.filter((u) => u.kind === "event").map((u) => (u.kind === "event" ? u.event.title : ""))).toEqual(["Zahnarzt"]);
    expect(d.searches[0]).toMatchObject({ id: search.id, first: { doctorName: "Dr. Berg" } });
  });
});
