// The native app's appointment routes (lib/appointments/app-routes.ts) through the family API,
// signed in with API tokens: members read, editors change, "run now" only queues.

import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { apptIgnored, apptSearches, calEvents, familyMembers, families } from "@/lib/db/schema";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { handleAppointmentsApp } from "@/lib/appointments/app-routes";
import { handleAppointments } from "@/lib/appointments/family-routes";
import { createChannel } from "@/lib/notifications/channels";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";
import { makeResult, makeRun, makeSearch } from "@/lib/test/appointments";

const BASE = "http://ohana.test/api/v1";

type Res = { status: number; data: any };

function setup() {
  const db = createTestDb();
  const handler = createFamilyApi([handleAppointmentsApp, handleAppointments], {
    db,
    appUrl: "http://ohana.test",
    now: () => NOW,
  });
  const as =
    (token: string) =>
    async (method: string, path: string, body?: unknown): Promise<Res> => {
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
      return { status: res.status, data: JSON.parse(await res.text()) };
    };
  const tokenOf = (userId: string) => createToken(db, { userId, kind: "api" }, NOW).token;
  const editor = makeUser(db, { email: "editor@test", name: "Sascha" });
  const viewer = makeUser(db, { email: "viewer@test", name: "Oma" });
  const stranger = makeUser(db, { email: "stranger@test" });
  const family = makeFamily(db, editor.id, [{ userId: viewer.id, role: "viewer" }]);
  const p = `/families/${family.id}/appointments`;
  return {
    db,
    family,
    p,
    edit: as(tokenOf(editor.id)),
    view: as(tokenOf(viewer.id)),
    other: as(tokenOf(stranger.id)),
    editor,
  };
}

const input = (over: Record<string, unknown> = {}) => ({
  name: "Dermatologist",
  sources: "doctolib",
  specialitySlug: "dermatologe",
  specialityLabel: "Dermatologe",
  latitude: "48.13",
  longitude: "11.57",
  locationLabel: "München",
  ...over,
});

/** A search with a finished run and one slot. */
function withSlot(s: ReturnType<typeof setup>, over: Parameters<typeof makeSearch>[2] = {}) {
  const search = makeSearch(s.db, s.family.id, { enabled: true, ...over });
  const run = makeRun(s.db, search.id, { slotsFound: 1, doctorsFound: 1, doctorsMatched: 1 });
  const result = makeResult(s.db, run.id, {
    practiceName: "Praxis A",
    practiceAddress: "Hauptstr. 1",
    practiceZipcode: "80331",
    practiceCity: "München",
    practiceLatitude: "48.14",
    practiceLongitude: "11.58",
    motiveLabel: "Erstuntersuchung",
  });
  return { search, run, result };
}

describe("app routes: appointments", () => {
  it("lists searches and booked appointments for members only", async () => {
    const s = setup();
    const { search } = withSlot(s);
    const res = await s.view("GET", s.p);
    expect(res.status).toBe(200);
    expect(res.data.searches).toHaveLength(1);
    expect(res.data.searches[0]).toMatchObject({ id: search.id, name: "Derm", runRequested: false });
    expect(res.data.searches[0].doctors[0]).toMatchObject({ doctorName: "Dr A", practiceName: "Praxis A" });
    expect(res.data.booked).toEqual([]);
    expect((await s.other("GET", s.p)).status).toBe(404);
  });

  it("gives the form's options: channels, people, home", async () => {
    const s = setup();
    createChannel(s.db, { id: s.editor.id }, s.family.id, { name: "Phone", provider: "PUSHBULLET", token: "tok" } as never, NOW);
    s.db.update(families).set({ homeAddress: "Marienplatz 1", homeLat: 48.137, homeLng: 11.575 }).where(eq(families.id, s.family.id)).run();
    const res = await s.view("GET", `${s.p}/options`);
    expect(res.status).toBe(200);
    expect(res.data.channels).toEqual([{ id: expect.any(String), name: "Phone", provider: "PUSHBULLET", enabled: true }]);
    expect(res.data.channels[0]).not.toHaveProperty("token");
    expect(res.data.people).toEqual(["Oma", "Sascha"]);
    expect(res.data.home).toEqual({ address: "Marienplatz 1", lat: 48.137, lng: 11.575 });
  });

  it("creates searches with the form's validation; viewers can't", async () => {
    const s = setup();
    const created = await s.edit("POST", `${s.p}/searches`, input());
    expect(created.status).toBe(201);
    const row = s.db.select().from(apptSearches).where(eq(apptSearches.id, created.data.id)).get()!;
    expect(row).toMatchObject({ name: "Dermatologist", specialitySlug: "dermatologe", enabled: true });
    expect(row.nextRunAt).not.toBeNull();

    const bad = await s.edit("POST", `${s.p}/searches`, input({ specialitySlug: "" }));
    expect(bad).toMatchObject({ status: 400, data: { error: "Pick a Doctolib speciality." } });
    const cron = await s.edit("POST", `${s.p}/searches`, input({ scheduleType: "CRON", cron: "* *" }));
    expect(cron.status).toBe(400);
    expect((await s.view("POST", `${s.p}/searches`, input())).status).toBe(403);
  });

  it("reads one search with the home, and its runs", async () => {
    const s = setup();
    const { search } = withSlot(s);
    const res = await s.view("GET", `${s.p}/searches/${search.id}`);
    expect(res.status).toBe(200);
    expect(res.data.search.id).toBe(search.id);
    expect(res.data.home).toBeNull();
    const runs = await s.view("GET", `${s.p}/searches/${search.id}/runs`);
    expect(runs.data.runs).toHaveLength(1);
    expect(runs.data.runs[0].run).toMatchObject({ status: "OK", slotsFound: 1 });
    expect(runs.data.runs[0].doctors).toHaveLength(1);
    expect((await s.view("GET", `${s.p}/searches/nope`)).status).toBe(404);
    expect((await s.view("GET", `${s.p}/searches/nope/runs`)).status).toBe(404);
  });

  it("run now only queues the search", async () => {
    const s = setup();
    const { search } = withSlot(s);
    expect((await s.view("POST", `${s.p}/searches/${search.id}/run`)).status).toBe(403);
    const res = await s.edit("POST", `${s.p}/searches/${search.id}/run`);
    expect(res).toMatchObject({ status: 200, data: { queued: search.id } });
    const row = s.db.select().from(apptSearches).where(eq(apptSearches.id, search.id)).get()!;
    expect(row.runRequestedAt?.getTime()).toBe(NOW.getTime());
    expect((await s.view("GET", `${s.p}/searches/${search.id}`)).data.search.runRequested).toBe(true);
  });

  it("turns a search off and on", async () => {
    const s = setup();
    const created = await s.edit("POST", `${s.p}/searches`, input());
    const id = created.data.id;
    const off = await s.edit("POST", `${s.p}/searches/${id}/enabled`, { enabled: false });
    expect(off).toMatchObject({ status: 200, data: { id, enabled: false } });
    let row = s.db.select().from(apptSearches).where(eq(apptSearches.id, id)).get()!;
    expect(row.enabled).toBe(false);
    expect(row.nextRunAt).toBeNull();
    expect(row.specialitySlug).toBe("dermatologe");
    await s.edit("POST", `${s.p}/searches/${id}/enabled`, { enabled: true });
    row = s.db.select().from(apptSearches).where(eq(apptSearches.id, id)).get()!;
    expect(row.enabled).toBe(true);
    expect(row.nextRunAt).not.toBeNull();
    expect((await s.edit("POST", `${s.p}/searches/${id}/enabled`, {})).status).toBe(400);
    expect((await s.view("POST", `${s.p}/searches/${id}/enabled`, { enabled: false })).status).toBe(403);
  });

  it("still updates and deletes through the existing routes", async () => {
    const s = setup();
    const { data } = await s.edit("POST", `${s.p}/searches`, input());
    const patched = await s.edit("PATCH", `${s.p}/searches/${data.id}`, input({ name: "Hautarzt" }));
    expect(patched).toMatchObject({ status: 200, data: { id: data.id } });
    const deleted = await s.edit("DELETE", `${s.p}/searches/${data.id}`);
    expect(deleted).toMatchObject({ status: 200, data: { deleted: data.id } });
  });

  it("shows a slot, books it into the calendar and removes the booking", async () => {
    const s = setup();
    const { search, result } = withSlot(s);
    const path = `${s.p}/searches/${search.id}/slots/${result.id}`;
    const before = await s.view("GET", path);
    expect(before.status).toBe(200);
    expect(before.data).toMatchObject({
      searchId: search.id,
      booking: null,
      searchEnabled: true,
      people: ["Oma", "Sascha"],
      homeLat: null,
      slot: { resultId: result.id, practiceCity: "München", source: "doctolib" },
    });

    expect((await s.view("POST", `${path}/book`, { date: "2026-11-03", start: "09:30" })).status).toBe(403);
    const booked = await s.edit("POST", `${path}/book`, {
      date: "2026-11-03",
      start: "09:30",
      end: "10:00",
      person: "Oma",
      note: "Card",
      stopSearch: true,
    });
    expect(booked.status).toBe(201);
    expect(booked.data.event).toMatchObject({ date: "2026-11-03", start: "09:30", end: "10:00", title: "Dr A", searchId: search.id });
    expect(s.db.select().from(apptSearches).where(eq(apptSearches.id, search.id)).get()!.enabled).toBe(false);
    expect((await s.edit("POST", `${path}/book`, { date: "2026-11-03", start: "09:30" })).status).toBe(409);

    const after = await s.view("GET", path);
    expect(after.data.booking).toEqual({ eventId: booked.data.eventId, date: "2026-11-03", start: "09:30", end: "10:00", person: "Oma" });
    const list = await s.view("GET", s.p);
    expect(list.data.booked.map((e: { id: string }) => e.id)).toEqual([booked.data.eventId]);

    expect((await s.view("DELETE", `${s.p}/bookings/${booked.data.eventId}`)).status).toBe(403);
    expect((await s.edit("DELETE", `${s.p}/bookings/${booked.data.eventId}`)).data).toEqual({ deleted: booked.data.eventId });
    expect(s.db.select().from(calEvents).all()).toHaveLength(0);
    expect((await s.edit("DELETE", `${s.p}/bookings/${booked.data.eventId}`)).status).toBe(404);
    expect((await s.view("GET", `${s.p}/searches/${search.id}/slots/999`)).status).toBe(404);
    expect((await s.view("GET", `${s.p}/searches/${search.id}/slots/x`)).status).toBe(404);
  });

  it("ignores a practice's motive and takes it back", async () => {
    const s = setup();
    const { search, result } = withSlot(s);
    expect((await s.view("POST", `${s.p}/results/${result.id}/ignore`)).status).toBe(403);
    const res = await s.edit("POST", `${s.p}/results/${result.id}/ignore`);
    expect(res).toMatchObject({ status: 200, data: { searchId: search.id } });
    const detail = await s.view("GET", `${s.p}/searches/${search.id}`);
    expect(detail.data.search.doctors).toEqual([]);
    expect(detail.data.search.ignored).toHaveLength(1);
    const entryId = detail.data.search.ignored[0].id;
    expect((await s.view("DELETE", `${s.p}/ignored/${entryId}`)).status).toBe(403);
    expect((await s.edit("DELETE", `${s.p}/ignored/${entryId}`)).data).toEqual({ deleted: entryId });
    expect(s.db.select().from(apptIgnored).all()).toHaveLength(0);
  });

  it("keeps other families' searches out", async () => {
    const s = setup();
    const otherOwner = makeUser(s.db, { email: "o@test" });
    const otherFamily = makeFamily(s.db, otherOwner.id);
    const { search, result } = withSlot({ ...s, family: otherFamily });
    expect((await s.edit("GET", `${s.p}/searches/${search.id}`)).status).toBe(404);
    expect((await s.edit("POST", `${s.p}/searches/${search.id}/run`)).status).toBe(404);
    expect((await s.edit("POST", `${s.p}/results/${result.id}/ignore`)).status).toBe(404);
    expect((await s.edit("GET", `${s.p}/searches/${search.id}/slots/${result.id}`)).status).toBe(404);
    // Members of the family only: the stranger isn't one.
    expect(s.db.select().from(familyMembers).where(eq(familyMembers.familyId, s.family.id)).all()).toHaveLength(2);
  });
});
