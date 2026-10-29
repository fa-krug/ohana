// Searches CRUD + roles, and the worker side: due / claim (no double runs), runClaimed
// (pipeline, notify, re-anchor, lease release), interrupted-run recovery, pruning and the
// non-blocking SearchRunner. Fake sources: nothing here touches the network.
import { eq } from "drizzle-orm";
import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import * as schema from "@/lib/db/schema";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";
import { makeRun, makeSearch } from "@/lib/test/appointments";
import { searchInputSchema } from "@/lib/appointments/schema";
import { createSearch, deleteSearch, requestRun, unignoreEntry, updateSearch } from "@/lib/appointments/searches";
import { claimSearch, dueSearches, pruneOldRuns, recoverStaleRuns, runClaimed } from "@/lib/appointments/tasks";
import { SearchRunner } from "@/lib/appointments/runner";
import { createChannel } from "@/lib/notifications/channels";
import type { AppointmentSource, CollectOutcome, NormalizedResult } from "@/lib/appointments/sources/types";
import { homeAddressSchema, setHomeAddress } from "@/lib/families/home";

const MIN = 60 * 1000;
const input = (over: Record<string, unknown> = {}) =>
  searchInputSchema.parse({ name: "Derm", specialitySlug: "hautarzt", latitude: "48.1", longitude: "11.5", ...over });

function result(over: Partial<NormalizedResult> = {}): NormalizedResult {
  return {
    source: "doctolib", doctorName: "Dr A", motiveLabel: "", practiceName: "", bookingUrl: "u", providerSlug: "dr-a",
    motiveId: 1, slotDatetime: new Date(NOW.getTime() + 86400000), isNextSlot: false, doctorSubtitle: "", speciality: "",
    practiceAddress: "", practiceCity: "", practiceZipcode: "", practiceLatitude: "", practiceLongitude: "", ...over,
  };
}

function fakeSource(outcome: Partial<CollectOutcome> | (() => Promise<CollectOutcome>), id: "doctolib" | "jameda" = "doctolib"): AppointmentSource {
  return {
    id,
    collectResults: typeof outcome === "function"
      ? outcome
      : async () => ({ results: [], skipped: [], doctorsFound: 0, doctorsMatched: 0, ...outcome }),
  };
}

let db: Db;
let editor: { id: string };
let viewer: { id: string };
let family: { id: string };

beforeEach(() => {
  process.env.SCHEDULE_JITTER_PERCENT = "0";
  db = createTestDb();
  editor = makeUser(db);
  viewer = makeUser(db);
  family = makeFamily(db, editor.id, [{ userId: viewer.id, role: "viewer" }]);
});

const get = (id: string) => db.select().from(schema.apptSearches).where(eq(schema.apptSearches.id, id)).get()!;

describe("searches", () => {
  it("creates a scheduled search with its channels; viewers can't", () => {
    const ch = createChannel(db, editor, family.id, { name: "P", provider: "PUSHBULLET", token: "t", target: "", smtpHost: "", smtpPort: 465, smtpUsername: "", smtpFrom: "", enabled: true }, NOW).id;
    const { id } = createSearch(db, editor, family.id, input({ channelIds: [ch, ch] }), NOW);
    expect(get(id).nextRunAt).toEqual(new Date(NOW.getTime() + 30 * MIN));
    expect(db.select().from(schema.apptSearchChannels).all()).toEqual([{ searchId: id, channelId: ch }]);
    expect(() => createSearch(db, viewer, family.id, input(), NOW)).toThrow(/editors/);
  });

  it("refuses a channel of another family", () => {
    const stranger = makeUser(db);
    const theirs = makeFamily(db, stranger.id);
    const ch = createChannel(db, stranger, theirs.id, { name: "P", provider: "PUSHBULLET", token: "t", target: "", smtpHost: "", smtpPort: 465, smtpUsername: "", smtpFrom: "", enabled: true }, NOW).id;
    expect(() => createSearch(db, editor, family.id, input({ channelIds: [ch] }), NOW)).toThrow(/Channel not found/);
    expect(db.select().from(schema.apptSearches).all()).toHaveLength(0); // rolled back
  });

  it("reschedules only when the cadence changes or the search is enabled; disabling clears it", () => {
    const { id } = createSearch(db, editor, family.id, input(), NOW);
    const first = get(id).nextRunAt;
    updateSearch(db, editor, family.id, id, input({ name: "Renamed" }), new Date(NOW.getTime() + MIN));
    expect(get(id).nextRunAt).toEqual(first);
    updateSearch(db, editor, family.id, id, input({ scheduleMinutes: 60 }), new Date(NOW.getTime() + MIN));
    expect(get(id).nextRunAt).toEqual(new Date(NOW.getTime() + 61 * MIN));
    updateSearch(db, editor, family.id, id, input({ enabled: false }), NOW);
    expect(get(id).nextRunAt).toBeNull();
  });

  it("hides other families' searches and lets viewers do nothing", () => {
    const s = makeSearch(db, family.id);
    const stranger = makeUser(db);
    const theirs = makeFamily(db, stranger.id);
    expect(() => deleteSearch(db, stranger, theirs.id, s.id)).toThrow(/Search not found/);
    expect(() => requestRun(db, viewer, family.id, s.id, NOW)).toThrow(/editors/);
    expect(() => unignoreEntry(db, viewer, family.id, 1)).toThrow(/editors/);
    deleteSearch(db, editor, family.id, s.id);
    expect(db.select().from(schema.apptSearches).all()).toHaveLength(0);
  });

  it("validates the input (sources need a speciality; cron needs 5 fields)", () => {
    expect(() => input({ specialitySlug: "" })).toThrow(/Doctolib speciality/);
    expect(() => input({ sources: "jameda", jamedaSpecialitySlug: "" })).toThrow(/jameda speciality/);
    expect(() => input({ scheduleType: "CRON", cron: "*/5 *" })).toThrow(/five fields/);
    expect(input({ scheduleType: "CRON", cron: "*/5 * * * *" }).cron).toBe("*/5 * * * *");
  });
});

describe("due + claim", () => {
  it("is due when nextRunAt passed; claiming advances it and leases the search", () => {
    const s = makeSearch(db, family.id, { nextRunAt: new Date(NOW.getTime() - MIN) });
    makeSearch(db, family.id, { nextRunAt: new Date(NOW.getTime() + MIN) }); // not yet
    makeSearch(db, family.id, { enabled: false, nextRunAt: new Date(NOW.getTime() - MIN) }); // disabled
    const due = dueSearches(db, NOW);
    expect(due.map((d) => d.id)).toEqual([s.id]);
    expect(claimSearch(db, due[0], NOW)).toEqual({ searchId: s.id, triggeredBy: "SCHEDULE" });
    expect(get(s.id).nextRunAt).toEqual(new Date(NOW.getTime() + 30 * MIN));
    expect(get(s.id).lockedUntil!.getTime()).toBeGreaterThan(NOW.getTime());
    expect(dueSearches(db, NOW)).toEqual([]);
  });

  it("never lets two workers claim the same search", () => {
    makeSearch(db, family.id, { nextRunAt: new Date(NOW.getTime() - MIN) });
    const [a] = dueSearches(db, NOW);
    const [b] = dueSearches(db, NOW); // a second worker read the same row
    expect(claimSearch(db, a, NOW)).not.toBeNull();
    expect(claimSearch(db, b, NOW)).toBeNull();
  });

  it("seeds a missing nextRunAt without firing", () => {
    const s = makeSearch(db, family.id, { nextRunAt: null });
    expect(dueSearches(db, NOW)).toEqual([]);
    expect(get(s.id).nextRunAt).toEqual(new Date(NOW.getTime() + 30 * MIN));
  });

  it("runs a 'Run now' request (also on a paused search) as MANUAL, first", () => {
    const sched = makeSearch(db, family.id, { nextRunAt: new Date(NOW.getTime() - 5 * MIN) });
    const paused = makeSearch(db, family.id, { enabled: false });
    requestRun(db, editor, family.id, paused.id, NOW);
    const due = dueSearches(db, NOW);
    expect(due.map((d) => d.id)).toEqual([paused.id, sched.id]);
    expect(claimSearch(db, due[0], NOW)).toEqual({ searchId: paused.id, triggeredBy: "MANUAL" });
    expect(get(paused.id).runRequestedAt).toBeNull();
  });

  it("waits for a running search, and takes over after the lease expired", () => {
    const s = makeSearch(db, family.id, { nextRunAt: new Date(NOW.getTime() - MIN), lockedUntil: new Date(NOW.getTime() + MIN) });
    requestRun(db, editor, family.id, s.id, NOW);
    expect(dueSearches(db, NOW)).toEqual([]);
    expect(dueSearches(db, new Date(NOW.getTime() + 2 * MIN)).map((d) => d.id)).toEqual([s.id]);
  });

  it("fires a CRON search once in a matching minute", () => {
    const at = new Date(2026, 10, 1, 8, 30, 10); // local 08:30:10
    const s = makeSearch(db, family.id, { scheduleType: "CRON", cron: "30 8 * * *", scheduleMinutes: null });
    expect(dueSearches(db, new Date(2026, 10, 1, 8, 29))).toEqual([]);
    const [due] = dueSearches(db, at);
    expect(claimSearch(db, due, at)).not.toBeNull();
    db.update(schema.apptSearches).set({ lockedUntil: null }).where(eq(schema.apptSearches.id, s.id)).run();
    expect(dueSearches(db, new Date(2026, 10, 1, 8, 30, 40))).toEqual([]); // same minute
  });
});

describe("runClaimed", () => {
  it("runs, stores, notifies on OK, re-anchors the schedule and releases the lease", async () => {
    const s = makeSearch(db, family.id, { nextRunAt: new Date(NOW.getTime() - MIN) });
    const claim = claimSearch(db, dueSearches(db, NOW)[0], NOW)!;
    const notified: string[] = [];
    const later = new Date(NOW.getTime() + 2 * MIN);
    const runId = await runClaimed(db, claim, {
      sources: [fakeSource({ results: [result()], doctorsFound: 3, doctorsMatched: 1 })],
      notify: async (_db, id) => (notified.push(id), true),
      now: () => later,
    });
    const run = db.select().from(schema.apptRuns).where(eq(schema.apptRuns.id, runId!)).get()!;
    expect(run).toMatchObject({ status: "OK", triggeredBy: "SCHEDULE", doctorsFound: 3, doctorsMatched: 1, slotsFound: 1 });
    expect(notified).toEqual([runId]);
    expect(get(s.id)).toMatchObject({ lastStatus: "OK", lockedUntil: null, nextRunAt: new Date(later.getTime() + 30 * MIN) });
  });

  it("records a failing source as ERROR without throwing, and doesn't notify", async () => {
    const s = makeSearch(db, family.id);
    requestRun(db, editor, family.id, s.id, NOW);
    const claim = claimSearch(db, dueSearches(db, NOW)[0], NOW)!;
    let notified = false;
    const runId = await runClaimed(db, claim, {
      sources: [fakeSource(async () => { throw new TypeError("fetch failed"); })],
      notify: async () => (notified = true),
    });
    const run = db.select().from(schema.apptRuns).where(eq(schema.apptRuns.id, runId!)).get()!;
    expect(run.status).toBe("ERROR");
    expect(run.triggeredBy).toBe("MANUAL");
    expect(run.errorMessage).toContain("fetch failed");
    expect(notified).toBe(false);
    expect(get(s.id).lockedUntil).toBeNull();
  });

  it("keeps the survivors when some providers fail (Skipped: …)", async () => {
    const s = makeSearch(db, family.id);
    requestRun(db, editor, family.id, s.id, NOW);
    const runId = await runClaimed(db, claimSearch(db, dueSearches(db, NOW)[0], NOW)!, {
      sources: [fakeSource({ results: [result()], doctorsFound: 2, doctorsMatched: 1, skipped: ["doctolib:dr-x: HTTP 410"] })],
      notify: async () => true,
    });
    const run = db.select().from(schema.apptRuns).where(eq(schema.apptRuns.id, runId!)).get()!;
    expect(run.status).toBe("OK");
    expect(run.errorMessage).toBe("Skipped: doctolib:dr-x: HTTP 410");
  });

  it("dedupes the same doctor across sources and applies the ignore list", async () => {
    const s = makeSearch(db, family.id, { sources: "both" });
    db.insert(schema.apptIgnored).values({ searchId: s.id, source: "doctolib", providerSlug: "dr-x", motiveId: 1, createdAt: NOW }).run();
    let seenIgnored: Set<string> | undefined;
    const doctolib: AppointmentSource = {
      id: "doctolib",
      collectResults: async (_db, _s, opts) => {
        seenIgnored = opts.ignored;
        return { results: [result({ practiceZipcode: "80331", slotDatetime: new Date(NOW.getTime() + 2 * 86400000) })], skipped: [], doctorsFound: 1, doctorsMatched: 1 };
      },
    };
    const jameda = fakeSource({ results: [result({ source: "jameda", providerSlug: "j1", motiveId: 0, practiceZipcode: "80331" })], doctorsFound: 1, doctorsMatched: 1 }, "jameda");
    requestRun(db, editor, family.id, s.id, NOW);
    const runId = await runClaimed(db, claimSearch(db, dueSearches(db, NOW)[0], NOW)!, { sources: [doctolib, jameda], notify: async () => true });
    expect([...seenIgnored!]).toEqual(["doctolib␟dr-x␟1"]);
    const rows = db.select().from(schema.apptResults).where(eq(schema.apptResults.runId, runId!)).all();
    expect(rows).toHaveLength(1);
    expect(rows[0].source).toBe("jameda"); // the earlier slot wins
  });
});

describe("maintenance", () => {
  it("marks RUNNING runs without a live lease as interrupted", () => {
    const free = makeSearch(db, family.id);
    const busy = makeSearch(db, family.id, { lockedUntil: new Date(NOW.getTime() + MIN) });
    const orphan = makeRun(db, free.id, { status: "RUNNING", finishedAt: null });
    const live = makeRun(db, busy.id, { status: "RUNNING", finishedAt: null });
    expect(recoverStaleRuns(db, NOW)).toBe(1);
    const status = (id: string) => db.select().from(schema.apptRuns).where(eq(schema.apptRuns.id, id)).get()!.status;
    expect(status(orphan.id)).toBe("ERROR");
    expect(status(live.id)).toBe("RUNNING");
  });

  it("prunes runs older than the retention", () => {
    const s = makeSearch(db, family.id);
    makeRun(db, s.id, { startedAt: new Date(NOW.getTime() - 31 * 86400000) });
    makeRun(db, s.id, { startedAt: new Date(NOW.getTime() - 29 * 86400000) });
    expect(pruneOldRuns(db, NOW, 30)).toBe(1);
    expect(db.select().from(schema.apptRuns).all()).toHaveLength(1);
  });
});

describe("SearchRunner", () => {
  it("starts due searches without waiting for them, at most maxConcurrent at once", async () => {
    for (let i = 0; i < 3; i++) makeSearch(db, family.id, { nextRunAt: new Date(NOW.getTime() - MIN) });
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const hanging = fakeSource(async () => {
      await gate;
      return { results: [], skipped: [], doctorsFound: 0, doctorsMatched: 0 };
    });
    const runner = new SearchRunner(db, 2, () => undefined, { sources: [hanging], notify: async () => true, now: () => NOW });
    expect(runner.tick(NOW)).toBe(2); // returns at once although both runs hang
    expect(runner.active).toBe(2);
    expect(runner.tick(NOW)).toBe(0); // full
    release();
    await new Promise((r) => setTimeout(r, 20));
    expect(runner.active).toBe(0);
    expect(runner.tick(NOW)).toBe(1); // the third one
    await runner.stop(1000);
    expect(db.select().from(schema.apptRuns).all().filter((r) => r.status === "NO_AVAILABILITY")).toHaveLength(3);
  });
});

describe("home address", () => {
  it("sets and clears the family's home address (editors only)", () => {
    setHomeAddress(db, editor, family.id, homeAddressSchema.parse({ address: "Marienplatz 1, München", lat: "48.137", lng: 11.575 }), NOW);
    let f = db.select().from(schema.families).where(eq(schema.families.id, family.id)).get()!;
    expect(f).toMatchObject({ homeAddress: "Marienplatz 1, München", homeLat: 48.137, homeLng: 11.575 });
    expect(() => setHomeAddress(db, viewer, family.id, { address: "", lat: null, lng: null }, NOW)).toThrow(/editors/);
    setHomeAddress(db, editor, family.id, { address: "", lat: null, lng: null }, NOW);
    f = db.select().from(schema.families).where(eq(schema.families.id, family.id)).get()!;
    expect(f).toMatchObject({ homeAddress: null, homeLat: null, homeLng: null });
  });
});
