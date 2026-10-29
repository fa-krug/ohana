// The assistant's appointment and calendar-event tools (lib/assistant/tools/appointments.ts,
// events.ts) against the in-memory database, with fake look-ups for Doctolib and the
// geocoder: "find a dermatologist before June", changing and running searches, a slot's
// details, marking it as booked, and the undo steps replayed through the family API.

import { eq } from "drizzle-orm";
import { afterEach, describe, expect, it } from "vitest";
import type { NetOptions } from "@/lib/assistant/net";
import { runTool, type ToolContext, TOOLS, toolsFor } from "@/lib/assistant/tools";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { findBooking, listEvents } from "@/lib/calendar/events";
import { apptSearchChannels, apptSearches, families, notificationChannels } from "@/lib/db/schema";
import { type AssistantTest, assistantTest, configure, type Event } from "@/lib/test/assistant";
import { makeResult, makeRun, makeSearch } from "@/lib/test/appointments";
import { NOW } from "@/lib/test/factories";
import { haversineKm } from "@/lib/appointments/distance";

let current: AssistantTest[] = [];
afterEach(async () => {
  await Promise.all(current.map((t) => t.stop()));
  current = [];
});

const TODAY = "2026-11-02";
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Res = { ok: boolean; result: any; summary: string; change?: any };

const lookups = {
  /** Doctolib blocks us. */
  down: false,
  async doctolibSpecialities(q: string) {
    if (lookups.down) throw new Error("blocked");
    return /haut|derma/i.test(q)
      ? [{ slug: "dermatologie-allergologie", label: "Dermatologie und Allergologie" }, { slug: "dermatologe", label: "Dermatologe" }]
      : [];
  },
  async places(q: string) {
    return /münchen/i.test(q) ? [{ label: "München, Bayern", latitude: "48.137", longitude: "11.575" }] : [];
  },
};

function family(opts: { home?: boolean; worker?: boolean } = {}) {
  const t = assistantTest({ worker: opts.worker ?? false, env: { lookups } });
  current.push(t);
  if (opts.home !== false) {
    t.db.update(families).set({ homeAddress: "Hauptstr. 1, 10115 Berlin", homeLat: 52.53, homeLng: 13.38 }).where(eq(families.id, t.familyId)).run();
  }
  const ctx = (userId = t.editor.id): ToolContext => ({
    lang: "en",
    calendar: new DrizzleCalendarStore(t.db),
    finance: new DrizzleFinanceStore(t.db),
    db: t.db,
    familyId: t.familyId,
    net: {} as NetOptions,
    search: null,
    userId,
    today: TODAY,
    now: () => NOW,
    lookups,
  });
  const tool = async (name: string, args: unknown, c = ctx()): Promise<Res> =>
    (await runTool(name, JSON.stringify(args), c, new Set(Object.keys(TOOLS)))) as Res;
  const undo = async (change: { undo: { method: string; path: string; body?: unknown }[] }) => {
    for (const step of change.undo) {
      const res = await t.call(step.method, t.f + step.path, step.body);
      expect(res.status, JSON.stringify(res.data)).toBeLessThan(300);
    }
  };
  return { t, ctx, tool, undo };
}

describe("creating a search", () => {
  it("finds a dermatologist before June: speciality, jameda term, home address, days", async () => {
    const f = family();
    f.t.db.insert(notificationChannels).values({ id: "ch1", familyId: f.t.familyId, name: "Phone", createdAt: NOW }).run();
    const res = await f.tool("create_appointment_search", { speciality: "Dermatologe", before: "2027-05-31", insurance: "public" });
    expect(res.ok, JSON.stringify(res.result)).toBe(true);
    expect(res.result).toMatchObject({
      name: "Dermatologe",
      doctolib: "Dermatologe",
      jameda: "Hautarzt (Dermatologe)",
      place: "Hauptstr. 1, 10115 Berlin",
      days: 210,
    });
    const s = f.t.db.select().from(apptSearches).where(eq(apptSearches.id, res.result.id)).get()!;
    expect(s).toMatchObject({
      familyId: f.t.familyId,
      sources: "both",
      specialitySlug: "dermatologe",
      jamedaSpecialitySlug: "hautarzt-dermatologe",
      jamedaSpecialityType: "specialization",
      latitude: "52.53",
      longitude: "13.38",
      insuranceSector: "public",
      jamedaInsuranceType: "government",
      dayLimit: 210,
      enabled: true,
    });
    expect(s.nextRunAt).not.toBeNull();
    // The family's channels notify.
    expect(f.t.db.select().from(apptSearchChannels).where(eq(apptSearchChannels.searchId, s.id)).all().map((c) => c.channelId)).toEqual(["ch1"]);
    expect(res.change.summary).toBe("Added the appointment search “Dermatologe”");
    await f.undo(res.change);
    expect(f.t.db.select().from(apptSearches).all()).toHaveLength(0);
  });

  it("searches around a place, with jameda alone when Doctolib can't be reached", async () => {
    const f = family();
    lookups.down = true;
    const res = await f.tool("create_appointment_search", { speciality: "Hautarzt", place: "München", days: 30, name: "Skin" });
    lookups.down = false;
    expect(res.ok, JSON.stringify(res.result)).toBe(true);
    const s = f.t.db.select().from(apptSearches).get()!;
    expect([s.name, s.sources, s.locationLabel, s.latitude, s.dayLimit]).toEqual(["Skin", "jameda", "München, Bayern", "48.137", 30]);
  });

  it("explains what's missing", async () => {
    const f = family({ home: false });
    expect((await f.tool("create_appointment_search", { speciality: "Hautarzt" })).result.error).toMatch(/no home address/);
    expect((await f.tool("create_appointment_search", { speciality: "Hautarzt", place: "Atlantis" })).result.error).toBe('No place found for "Atlantis"');
    expect((await f.tool("create_appointment_search", { speciality: "Quantenheiler", place: "München" })).result.error).toMatch(/No speciality found/);
    expect((await f.tool("create_appointment_search", { speciality: "Hautarzt", place: "München", before: "2026-10-01" })).result.error).toBe(
      "before must be after today",
    );
    expect(f.t.db.select().from(apptSearches).all()).toHaveLength(0);
  });

  it("looks specialities up for the model", async () => {
    const f = family();
    const res = await f.tool("find_doctor_specialities", { query: "Hautarzt" });
    expect(res.result.doctolib.map((d: { slug: string }) => d.slug)).toContain("dermatologe");
    expect(res.result.jameda.map((d: { slug: string }) => d.slug)).toContain("hautarzt-dermatologe");
    lookups.down = true;
    expect((await f.tool("find_doctor_specialities", { query: "Hautarzt" })).result.doctolib).toBeNull();
    lookups.down = false;
  });
});

describe("searches and slots", () => {
  function withResults(f: ReturnType<typeof family>) {
    const s = makeSearch(f.t.db, f.t.familyId, {
      name: "Derm",
      enabled: true,
      specialitySlug: "dermatologe",
      latitude: "52.5",
      longitude: "13.4",
      locationLabel: "Berlin",
      nextRunAt: NOW,
    });
    const run = makeRun(f.t.db, s.id);
    const early = makeResult(f.t.db, run.id, {
      doctorName: "Dr. Haut",
      practiceName: "Praxis Haut",
      practiceAddress: "Ring 2",
      practiceZipcode: "10117",
      practiceCity: "Berlin",
      practiceLatitude: "52.52",
      practiceLongitude: "13.40",
      motiveLabel: "Erstuntersuchung",
      slotDatetime: new Date("2026-11-20T08:30:00Z"),
    });
    makeResult(f.t.db, run.id, { doctorName: "Dr. Later", providerSlug: "dr-later", slotDatetime: new Date("2026-12-20T09:00:00Z") });
    return { s, early };
  }

  it("lists the searches with their earliest finds", async () => {
    const f = family();
    const { early } = withResults(f);
    const res = await f.tool("list_appointment_searches", {});
    expect(res.result.searches).toHaveLength(1);
    const s = res.result.searches[0];
    expect([s.name, s.enabled, s.lastRun.status]).toEqual(["Derm", true, "OK"]);
    expect(s.earliest.map((d: { doctor: string }) => d.doctor)).toEqual(["Dr. Haut", "Dr. Later"]);
    expect(s.earliest[0]).toMatchObject({ resultId: early.id, practice: "Praxis Haut", city: "Berlin" });
  });

  it("change a search (off, another deadline) and undo puts it back", async () => {
    const f = family();
    const { s } = withResults(f);
    const res = await f.tool("change_appointment_search", { search: "derm", enabled: false, days: 60 });
    expect(res.ok, JSON.stringify(res.result)).toBe(true);
    let row = f.t.db.select().from(apptSearches).where(eq(apptSearches.id, s.id)).get()!;
    expect([row.enabled, row.dayLimit, row.nextRunAt]).toEqual([false, 60, null]);
    await f.undo(res.change);
    row = f.t.db.select().from(apptSearches).where(eq(apptSearches.id, s.id)).get()!;
    expect([row.enabled, row.dayLimit]).toEqual([true, s.dayLimit]);
    expect((await f.tool("change_appointment_search", { search: "nope" })).result.error).toBe('No appointment search "nope"');
  });

  it("run a search now: only queued for the worker", async () => {
    const f = family();
    const { s } = withResults(f);
    const res = await f.tool("run_appointment_search", { search: s.id });
    expect(res.ok).toBe(true);
    expect(f.t.db.select().from(apptSearches).get()!.runRequestedAt).not.toBeNull();
  });

  it("read a slot with the distance from home, and mark it booked (stopping the search); undo", async () => {
    const f = family();
    const { s, early } = withResults(f);
    const slot = await f.tool("get_appointment_slot", { search: "Derm", resultId: early.id });
    expect(slot.result).toMatchObject({ doctorName: "Dr. Haut", booked: null });
    expect(slot.result.kmFromHome).toBeCloseTo(haversineKm(52.53, 13.38, 52.52, 13.4), 1);
    const at = new Date("2026-11-20T08:30:00Z");
    const pad = (n: number) => String(n).padStart(2, "0");
    expect(slot.result.localTime).toBe(`${pad(at.getHours())}:${pad(at.getMinutes())}`);

    const res = await f.tool("book_appointment_slot", { search: "Derm", resultId: early.id, person: "Mia", stopSearch: true });
    expect(res.ok, JSON.stringify(res.result)).toBe(true);
    const event = res.result.event;
    expect(event).toMatchObject({ title: "Dr. Haut", person: "Mia", start: slot.result.localTime, date: slot.result.localDay, source: "appointment" });
    expect(event.location).toBe("Praxis Haut, Ring 2, 10117 Berlin");
    expect(f.t.db.select().from(apptSearches).get()!.enabled).toBe(false);
    expect((await f.tool("book_appointment_slot", { search: "Derm", resultId: early.id })).result.error).toBe("This slot is booked already.");
    expect((await f.tool("get_appointment_slot", { search: "Derm", resultId: early.id })).result.booked.id).toBe(event.id);

    await f.undo(res.change);
    expect(findBooking(f.t.db, f.t.familyId, s.id, early.id)).toBeNull();
    expect(f.t.db.select().from(apptSearches).get()!.enabled).toBe(true);
  });
});

describe("calendar events", () => {
  it("add, list and remove events; removing a booking and undoing keeps it the slot's booking", async () => {
    const f = family();
    const add = await f.tool("add_event", { date: "2026-11-10", start: "15:00", title: "Parents' evening", location: "School" });
    expect(add.ok, JSON.stringify(add.result)).toBe(true);
    const list = await f.tool("list_events", { from: "2026-11-01", to: "2026-11-30" });
    expect(list.result.events.map((e: { title: string }) => e.title)).toEqual(["Parents' evening"]);
    await f.undo(add.change);
    expect(listEvents(f.t.db, f.t.familyId)).toHaveLength(0);
    expect((await f.tool("add_event", { date: "2026-11-10", start: "25:00", title: "x" })).result.error).toMatch(/start/);

    const s = makeSearch(f.t.db, f.t.familyId, { name: "Derm" });
    const run = makeRun(f.t.db, s.id);
    const r = makeResult(f.t.db, run.id);
    const booked = await f.tool("book_appointment_slot", { search: "Derm", resultId: r.id });
    const id = booked.result.event.id;
    const removed = await f.tool("remove_event", { id });
    expect(removed.ok).toBe(true);
    expect(findBooking(f.t.db, f.t.familyId, s.id, r.id)).toBeNull();
    await f.undo(removed.change);
    expect(findBooking(f.t.db, f.t.familyId, s.id, r.id)?.title).toBe("Dr A");
    expect((await f.tool("remove_event", { id: "nope" })).result.error).toBe('No event "nope"');
  });
});

describe("permissions", () => {
  it("viewers and families with changes off get only the tools that read", () => {
    const names = toolsFor({ writes: false, search: false }).map((t) => t.function.name);
    for (const n of ["list_appointment_searches", "find_doctor_specialities", "get_appointment_slot", "list_events"]) {
      expect(names).toContain(n);
    }
    for (const n of ["create_appointment_search", "change_appointment_search", "run_appointment_search", "book_appointment_slot", "add_event", "remove_event"]) {
      expect(names).not.toContain(n);
    }
  });

  it("a viewer can't change searches, even if a write tool were called", async () => {
    const f = family();
    const res = await f.tool("create_appointment_search", { speciality: "Hautarzt" }, f.ctx(f.t.viewer.id));
    expect([res.ok, res.result.error]).toEqual([false, "Only editors can do this."]);
    const s = makeSearch(f.t.db, f.t.familyId, { name: "Derm" });
    expect((await f.t.view("DELETE", `${f.t.f}/appointments/searches/${s.id}`)).status).toBe(403);
    expect((await f.t.view("POST", `${f.t.f}/events`, { date: "2026-11-10", title: "x" })).status).toBe(403);
    // Another family's search can't be put back as a booking.
    const other = family();
    const res2 = await other.t.call("POST", `${other.t.f}/events`, { date: "2026-11-10", title: "x", searchId: s.id, resultId: 1 });
    expect(res2.status).toBe(404);
  });
});

describe("in a chat", () => {
  it("finds a dermatologist before June through the worker", async () => {
    const f = family({ worker: true });
    await configure(f.t);
    const res = await f.t.call("POST", `${f.t.ai}/chats`, {
      text: "find a Hautarzt before 2027-05-31",
      today: TODAY,
      year: 2026,
      lang: "de",
      page: "appointments",
    });
    expect(res.status).toBe(200);
    const items = (res.data as Event[]).filter((e) => e.event === "items").flatMap((e) => e.data.items.map((i: { item: unknown }) => i.item));
    const change = items.find((i: { kind: string }) => i.kind === "change");
    expect(change, JSON.stringify(items)).toMatchObject({ change: "appointments", summary: "Terminsuche „Dermatologie und Allergologie“ angelegt" });
    expect(items.at(-1)).toMatchObject({ kind: "assistant", text: "Search “Dermatologie und Allergologie” is set up." });
    expect(f.t.db.select().from(apptSearches).get()!.dayLimit).toBe(210);
  });
});
