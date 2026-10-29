// Ports of findmyappointment's DB-backed tests (schema defaults, search detail, slot
// detail, source-aware ignoring, store results, profile cache), on families.
import { eq } from "drizzle-orm";
import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import * as schema from "@/lib/db/schema";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";
import { makeResult, makeRun, makeSearch } from "@/lib/test/appointments";
import { getSearchDetail, getSlotDetail, listRunsWithResults, listSearchesWithLatest } from "@/lib/appointments/serialize";
import { ignoreResult } from "@/lib/appointments/searches";
import { storeResults } from "@/lib/appointments/pipeline";
import { loadProfilePayload } from "@/lib/appointments/doctolib/profile-cache";

let db: Db;
let editor: { id: string };
let family: { id: string };
let other: { id: string };

beforeEach(() => {
  db = createTestDb();
  editor = makeUser(db);
  family = makeFamily(db, editor.id);
  other = makeFamily(db, makeUser(db).id);
});

describe("source columns", () => {
  it("defaults searches.sources and result/ignore source to doctolib", () => {
    const s = makeSearch(db, family.id);
    expect(s.sources).toBe("doctolib");
    expect(s.jamedaSpecialitySlug).toBe("");
    expect(s.jamedaVideo).toBe("any");
    const run = makeRun(db, s.id);
    const r = db.insert(schema.apptResults).values({ runId: run.id, doctorName: "D", bookingUrl: "u", slotDatetime: NOW }).returning().get();
    expect(r.source).toBe("doctolib");
  });

  it("allows the same (slug, motive) ignored under two different sources", () => {
    const s = makeSearch(db, family.id);
    db.insert(schema.apptIgnored).values({ searchId: s.id, source: "doctolib", providerSlug: "x", motiveId: 1, createdAt: NOW }).run();
    expect(() =>
      db.insert(schema.apptIgnored).values({ searchId: s.id, source: "jameda", providerSlug: "x", motiveId: 1, createdAt: NOW }).run(),
    ).not.toThrow();
  });

  it("deleting the family deletes its searches, runs and results", () => {
    const s = makeSearch(db, family.id);
    makeResult(db, makeRun(db, s.id).id);
    db.delete(schema.families).where(eq(schema.families.id, family.id)).run();
    expect(db.select().from(schema.apptResults).all()).toHaveLength(0);
    expect(db.select().from(schema.apptSearches).all()).toHaveLength(0);
  });
});

function seedDetail() {
  const s = makeSearch(db, family.id, { id: "s1" });
  makeRun(db, s.id, { id: "r1", startedAt: new Date("2026-07-01T08:00:00Z"), status: "ERROR", errorMessage: "boom" });
  makeRun(db, s.id, { id: "r2", startedAt: new Date("2026-07-01T09:00:00Z"), status: "OK", triggeredBy: "MANUAL", doctorsFound: 2, doctorsMatched: 2, slotsFound: 3, notified: true });
  makeResult(db, "r2", { doctorName: "Dr A", motiveLabel: "First", practiceName: "P1", bookingUrl: "http://x/a2", providerSlug: "dr-a", motiveId: 1, slotDatetime: new Date("2026-07-05T10:00:00Z") });
  makeResult(db, "r2", { doctorName: "Dr A", motiveLabel: "First", practiceName: "P1", bookingUrl: "http://x/a1", providerSlug: "dr-a", motiveId: 1, slotDatetime: new Date("2026-07-03T10:00:00Z") });
  makeResult(db, "r2", { doctorName: "Dr B", motiveLabel: "Skip", practiceName: "P2", bookingUrl: "http://x/b", providerSlug: "dr-b", motiveId: 9, slotDatetime: new Date("2026-07-04T10:00:00Z"), isNextSlot: true });
  db.insert(schema.apptIgnored).values({ searchId: "s1", providerSlug: "dr-b", motiveId: 9, doctorName: "Dr B", motiveLabel: "Skip", createdAt: NOW }).run();
  return s;
}

describe("getSearchDetail", () => {
  it("returns the search with latest run and earliest-per-doctor, ignored filtered", () => {
    seedDetail();
    const detail = getSearchDetail(db, family.id, "s1");
    expect(detail).not.toBeNull();
    expect(detail!.name).toBe("Derm");
    expect(detail!.latestRun?.id).toBe("r2");
    expect(detail!.doctors).toHaveLength(1); // Dr B ignored, Dr A collapsed to earliest
    expect(detail!.doctors[0].doctorName).toBe("Dr A");
    expect(detail!.doctors[0].slot).toBe("2026-07-03T10:00:00.000Z");
    expect(detail!.ignored).toHaveLength(1);
    expect(detail!.runRequested).toBe(false);
  });

  it("keeps the previous run's results while a newer run is still RUNNING", () => {
    seedDetail();
    makeRun(db, "s1", { id: "r3", startedAt: new Date("2026-07-01T10:00:00Z"), finishedAt: null, status: "RUNNING", triggeredBy: "MANUAL" });
    const detail = getSearchDetail(db, family.id, "s1");
    expect(detail!.latestRun?.id).toBe("r3");
    expect(detail!.latestRun?.status).toBe("RUNNING");
    expect(detail!.doctors).toHaveLength(1);
    expect(detail!.doctors[0].doctorName).toBe("Dr A");
  });

  it("returns null for a search in another family", () => {
    seedDetail();
    expect(getSearchDetail(db, other.id, "s1")).toBeNull();
  });

  it("lists only the family's searches", () => {
    seedDetail();
    makeSearch(db, other.id, { name: "Theirs" });
    expect(listSearchesWithLatest(db, family.id).map((s) => s.name)).toEqual(["Derm"]);
  });

  it("round-trips jamedaVideo", () => {
    makeSearch(db, family.id, { id: "v", jamedaVideo: "only" });
    expect(getSearchDetail(db, family.id, "v")!.jamedaVideo).toBe("only");
  });
});

describe("listRunsWithResults", () => {
  it("lists runs newest-first, each with its own results (ignored filtered)", () => {
    seedDetail();
    const runs = listRunsWithResults(db, family.id, "s1");
    expect(runs.map((r) => r.run.id)).toEqual(["r2", "r1"]);
    expect(runs[0].doctors).toHaveLength(1);
    expect(runs[1].doctors).toHaveLength(0);
  });

  it("returns [] for a search in another family", () => {
    seedDetail();
    expect(listRunsWithResults(db, other.id, "s1")).toEqual([]);
  });
});

describe("getSlotDetail", () => {
  function seedSlot() {
    db.update(schema.families).set({ homeLat: 48.1, homeLng: 11.44, homeAddress: "Home" }).where(eq(schema.families.id, family.id)).run();
    const s = makeSearch(db, family.id, { id: "S1", specialityLabel: "Dermatologist", insuranceSector: "public" });
    const run = makeRun(db, s.id);
    return makeResult(db, run.id, {
      doctorSubtitle: "Specialist", speciality: "Dermatology", practiceName: "Clinic A", practiceAddress: "Main St 1",
      practiceCity: "Munich", practiceZipcode: "80331", practiceLatitude: "48.13", practiceLongitude: "11.58",
    });
  }

  it("returns the slot with practice + home coords for the owning family", () => {
    const r = seedSlot();
    const d = getSlotDetail(db, family.id, "S1", r.id)!;
    expect(d.slot.resultId).toBe(r.id);
    expect(d.homeLat).toBe(48.1);
    expect(d.searchId).toBe("S1");
    expect(d.slot.doctorSubtitle).toBe("Specialist");
    expect(d.slot.practiceCity).toBe("Munich");
    expect(d.specialityLabel).toBe("Dermatologist");
    expect(d.insuranceSector).toBe("public");
  });

  it("returns null for a different family, another search or an unknown result", () => {
    const r = seedSlot();
    expect(getSlotDetail(db, other.id, "S1", r.id)).toBeNull();
    expect(getSlotDetail(db, family.id, "OTHER", r.id)).toBeNull();
    expect(getSlotDetail(db, family.id, "S1", 999999)).toBeNull();
  });
});

describe("source-aware ignoring", () => {
  it("writes source to the ignore list and only filters the matching source's result", () => {
    const s = makeSearch(db, family.id, { id: "s1" });
    const run = makeRun(db, s.id);
    makeResult(db, run.id, { doctorName: "Dr A", providerSlug: "dr-a", motiveId: 1, source: "doctolib", bookingUrl: "http://doctolib/a", slotDatetime: new Date("2026-07-10T10:00:00Z") });
    const jameda = makeResult(db, run.id, { doctorName: "Dr A", providerSlug: "dr-a", motiveId: 1, source: "jameda", bookingUrl: "http://jameda/a", slotDatetime: new Date("2026-07-11T10:00:00Z") });

    ignoreResult(db, editor, family.id, jameda.id, NOW);
    const entries = db.select().from(schema.apptIgnored).all();
    expect(entries).toHaveLength(1);
    expect(entries[0].source).toBe("jameda");
    expect(entries[0].providerSlug).toBe("dr-a");

    const doctors = listRunsWithResults(db, family.id, "s1")[0].doctors;
    expect(doctors).toHaveLength(1);
    expect(doctors[0].source).toBe("doctolib");
    expect(doctors[0].bookingUrl).toBe("http://doctolib/a");
  });

  it("is idempotent", () => {
    const s = makeSearch(db, family.id);
    const r = makeResult(db, makeRun(db, s.id).id);
    ignoreResult(db, editor, family.id, r.id, NOW);
    ignoreResult(db, editor, family.id, r.id, NOW);
    expect(db.select().from(schema.apptIgnored).all()).toHaveLength(1);
  });
});

describe("storeResults", () => {
  function rows(n: number) {
    return Array.from({ length: n }, (_, i) => ({
      source: "doctolib" as const, doctorName: `Dr ${i}`, motiveLabel: "Sprechstunde", practiceName: "Praxis",
      bookingUrl: "https://x/booking", providerSlug: `dr-${i}`, motiveId: i, slotDatetime: NOW, isNextSlot: false,
      doctorSubtitle: "", speciality: "", practiceAddress: "", practiceCity: "", practiceZipcode: "",
      practiceLatitude: "", practiceLongitude: "",
    }));
  }

  it("stores a result set larger than SQLite's single-statement variable limit", () => {
    const run = makeRun(db, makeSearch(db, family.id).id);
    storeResults(db, run.id, rows(3000));
    expect(db.select().from(schema.apptResults).where(eq(schema.apptResults.runId, run.id)).all()).toHaveLength(3000);
  });

  it("is a no-op for an empty result set", () => {
    const run = makeRun(db, makeSearch(db, family.id).id);
    expect(() => storeResults(db, run.id, [])).not.toThrow();
  });
});

describe("loadProfilePayload", () => {
  const DAY = 24 * 60 * 60 * 1000;
  const WEEK = 7 * DAY;
  const now = new Date("2026-07-01T09:00:00Z");

  it("fetches and stores on a cache miss", async () => {
    let calls = 0;
    const payload = await loadProfilePayload(db, "dr-a", now, WEEK, async () => {
      calls += 1;
      return { data: { profile: { name: "Dr A" } } };
    });
    expect(calls).toBe(1);
    expect(payload).toEqual({ data: { profile: { name: "Dr A" } } });
    const rows = db.select().from(schema.apptProfileCache).all();
    expect(rows).toHaveLength(1);
    expect(rows[0].providerSlug).toBe("dr-a");
  });

  it("returns the cached payload without fetching when fresh", async () => {
    let calls = 0;
    const fetcher = async () => ({ n: ++calls });
    await loadProfilePayload(db, "dr-a", now, WEEK, fetcher);
    const second = await loadProfilePayload(db, "dr-a", new Date(now.getTime() + 6 * DAY), WEEK, fetcher);
    expect(calls).toBe(1);
    expect(second).toEqual({ n: 1 });
  });

  it("refetches and updates when the entry is older than the TTL", async () => {
    let calls = 0;
    const fetcher = async () => ({ n: ++calls });
    await loadProfilePayload(db, "dr-a", now, WEEK, fetcher);
    const later = new Date(now.getTime() + 8 * DAY);
    const second = await loadProfilePayload(db, "dr-a", later, WEEK, fetcher);
    expect(calls).toBe(2);
    expect(second).toEqual({ n: 2 });
    const rows = db.select().from(schema.apptProfileCache).all();
    expect(rows).toHaveLength(1);
    expect(rows[0].fetchedAt.getTime()).toBe(later.getTime());
  });
});
