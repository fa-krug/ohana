// Phase 11, the week ahead against the database: the digest (GET /digest, dismissing and
// restoring issues), the overview's card, the weekly notification (channels and each member's
// app devices), the geocoding cache the worker fills, the assistant's check_schedule and the
// cleanup. Nothing touches the network: the geocoder, channels and the push relay are fakes.

import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createFamilyApi } from "@/lib/api/family-api";
import { runTool, TOOLS, type ToolContext } from "@/lib/assistant/tools";
import type { NetOptions } from "@/lib/assistant/net";
import { createToken } from "@/lib/auth/tokens";
import { createEvent, type EventInput } from "@/lib/calendar/events";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import type { Db } from "@/lib/db";
import * as schema from "@/lib/db/schema";
import { type Issue, ISSUE_KINDS, type IssueKind } from "@/lib/digest/checks";
import { buildDigest, digestSchedule, dismissIssue, issueSentence, sendWeeklyDigest, weeklyDigests } from "@/lib/digest/digest";
import { cachedPlaces, type PlaceLookup, refreshPlaces } from "@/lib/digest/geo";
import { handleDigest } from "@/lib/digest/routes";
import type { Coord } from "@/lib/digest/travel";
import { familyDashboard } from "@/lib/families/dashboard";
import { addPerson } from "@/lib/families/people";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { cleanup } from "@/lib/maintenance/cleanup";
import type { Channel, Message } from "@/lib/notifications";
import { createChannel } from "@/lib/notifications/channels";
import { translator } from "@/lib/notifications/locale";
import { readState, setPref } from "@/lib/notifications/prefs";
import { DEFAULT_PUSH_RELAY_URL } from "@/lib/push/config";
import { registerDevice } from "@/lib/push/devices";
import { openPayload } from "@/lib/push/payload";
import type { RelayClient, RelayMessage } from "@/lib/push/relay";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const BASE = "http://ohana.test/api/v1";
const TODAY = "2026-11-02"; // a Monday
const DAY_MS = 86_400_000;

type Res = { status: number; data: any };

let db: Db;
let familyId: string;
let anna: { id: string };
let ben: { id: string };
let maxId: string;

beforeEach(() => {
  db = createTestDb();
  anna = makeUser(db, { name: "Anna", email: "anna@test" });
  ben = makeUser(db, { name: "Ben", email: "ben@test" });
  familyId = makeFamily(db, anna.id, [{ userId: ben.id, role: "viewer" }]).id;
  maxId = addPerson(db, { id: anna.id }, familyId, { name: "Max", birthday: "2016-11-06" }, NOW).person.id;
});
afterEach(() => vi.unstubAllEnvs());

const event = (input: EventInput) => createEvent(db, familyId, input, {}, NOW);

/** Anna and Ben each double-booked, Max in two places at once with only Anna free, and an
 *  unassigned clash (info). */
function clashes() {
  event({ date: "2026-11-03", start: "09:00", end: "10:00", title: "Dentist", person: "Anna" });
  event({ date: "2026-11-03", start: "09:30", end: "10:30", title: "Meeting", person: "Anna" });
  event({ date: "2026-11-04", start: "09:00", end: "10:00", title: "Gym", person: "Ben" });
  event({ date: "2026-11-04", start: "09:30", end: "10:30", title: "Call", person: "Ben" });
  event({ date: "2026-11-05", start: "16:00", end: "17:00", title: "Football", person: "Max" });
  event({ date: "2026-11-05", start: "16:30", end: "17:00", title: "Piano", person: "Max" });
  event({ date: "2026-11-06", start: "18:00", end: "19:00", title: "Plumber" });
  event({ date: "2026-11-06", start: "18:30", end: "19:00", title: "Parents' evening" });
}

function setHome(lat = 52.52, lng = 13.405) {
  db.update(schema.families).set({ homeAddress: "Home", homeLat: lat, homeLng: lng }).where(eq(schema.families.id, familyId)).run();
}

function away(days: string[]) {
  db.insert(schema.calEntryTypes)
    .values({ familyId, year: 2026, id: "trip", name: "Trip", color: "#00f", role: "none", position: 9, away: true })
    .onConflictDoNothing()
    .run();
  for (const day of days) db.insert(schema.calEntries).values({ familyId, day, year: 2026, typeId: "trip" }).run();
}

// ---- the routes ----

function api() {
  const handler = createFamilyApi([handleDigest], { db, appUrl: "http://ohana.test", now: () => NOW });
  return (userId: string) =>
    async (method: string, path: string, body?: unknown): Promise<Res> => {
      const token = createToken(db, { userId, kind: "api" }, NOW).token;
      const res = await handler(
        new Request(`${BASE}/families/${familyId}${path}`, {
          method,
          headers: { authorization: `Bearer ${token}`, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
          body: body !== undefined ? JSON.stringify(body) : undefined,
        }),
      );
      const text = await res.text();
      return { status: res.status, data: text ? JSON.parse(text) : null };
    };
}

describe("GET /digest", () => {
  it("answers the next 14 days: people, issues, away runs and birthdays", async () => {
    clashes();
    away(["2026-11-12", "2026-11-13", "2026-11-20"]);
    db.update(schema.familyMembers).set({ birthday: "1990-11-14" }).where(eq(schema.familyMembers.userId, ben.id)).run();
    const res = await api()(ben.id)("GET", `/digest?today=${TODAY}`);
    expect(res.status).toBe(200);
    expect(Object.keys(res.data).sort()).toEqual(["away", "birthdays", "from", "geocoding", "issues", "people", "to"]);
    expect(res.data).toMatchObject({ from: TODAY, to: "2026-11-15", geocoding: true });
    expect(res.data.people).toEqual([
      { id: anna.id, name: "Anna", account: true, child: false, events: 2 },
      { id: ben.id, name: "Ben", account: true, child: false, events: 2 },
      { id: maxId, name: "Max", account: false, child: true, events: 2 },
    ]);
    expect(res.data.away).toEqual([{ from: "2026-11-12", to: "2026-11-13", names: ["Trip"] }]);
    expect(res.data.birthdays).toEqual([
      { day: "2026-11-06", name: "Max", age: 10 },
      { day: "2026-11-14", name: "Ben", age: 36 },
    ]);
    expect(res.data.issues.map((i: any) => [i.kind, i.date, i.people.map((p: any) => p.name), i.dismissed])).toEqual([
      ["overlap", "2026-11-03", ["Anna"], false],
      ["overlap", "2026-11-04", ["Ben"], false],
      ["overlap", "2026-11-05", ["Max"], false],
      ["unassigned_overlap", "2026-11-06", [], false],
    ]);
    const first = res.data.issues[0];
    expect(Object.keys(first).sort()).toEqual(["data", "date", "dismissed", "events", "key", "kind", "people", "severity"]);
    expect(Object.keys(first.events[0]).sort()).toEqual(["date", "end", "endDate", "id", "location", "occurrence", "start", "title"]);
  });

  it("uses the server's day without a valid one, and hides the family from others", async () => {
    const as = api();
    expect((await as(anna.id)("GET", "/digest?today=nope")).data.from).toBe("2026-11-01");
    const outsider = makeUser(db);
    expect((await as(outsider.id)("GET", "/digest")).status).toBe(404);
    expect((await as(outsider.id)("POST", "/digest/dismiss", { key: "overlap:x" })).status).toBe(404);
    expect((await as(anna.id)("POST", "/digest")).status).toBe(405);
    expect((await as(anna.id)("GET", "/digest/dismiss")).status).toBe(405);
    expect((await as(anna.id)("GET", "/digest/other")).status).toBe(404);
  });
});

describe("dismissing", () => {
  it("hides an issue for good (editors), shows it as dismissed and restores it", async () => {
    clashes();
    const as = api();
    const issues = (await as(anna.id)("GET", `/digest?today=${TODAY}`)).data.issues;
    const key = issues[1].key as string;

    expect((await as(ben.id)("POST", "/digest/dismiss", { key })).status).toBe(403);
    expect((await as(anna.id)("POST", "/digest/dismiss", {})).status).toBe(400);
    expect((await as(anna.id)("POST", "/digest/dismiss", { key: "nonsense" })).status).toBe(400);
    expect((await as(anna.id)("POST", "/digest/dismiss", { key, today: TODAY })).status).toBe(204);
    const rows = db.select().from(schema.digestDismissals).all();
    expect(rows).toEqual([expect.objectContaining({ familyId, key, day: "2026-11-04", createdById: anna.id })]);

    const after = (await as(ben.id)("GET", `/digest?today=${TODAY}`)).data.issues;
    expect(after.map((i: any) => i.dismissed)).toEqual([false, true, false, false]);
    // The overview counts only open ones.
    const overview = (await familyDashboard(db, familyId, TODAY)).weekAhead;
    expect(overview.conflicts).toBe(2);
    expect(overview.top.map((i) => i.key)).not.toContain(key);

    expect((await as(ben.id)("DELETE", `/digest/dismiss/${encodeURIComponent(key)}`)).status).toBe(403);
    expect((await as(anna.id)("DELETE", `/digest/dismiss/${encodeURIComponent(key)}`)).status).toBe(204);
    expect((await as(anna.id)("GET", `/digest?today=${TODAY}`)).data.issues[1].dismissed).toBe(false);
    // Restoring again is fine.
    expect((await as(anna.id)("DELETE", `/digest/dismiss/${encodeURIComponent(key)}`)).status).toBe(204);
  });

  it("keeps a key it doesn't know until the end of the two weeks, and the cleanup prunes past days", async () => {
    const as = api();
    expect((await as(anna.id)("POST", `/digest/dismiss?today=${TODAY}`, { key: "overlap:gone" })).status).toBe(204);
    expect(db.select().from(schema.digestDismissals).get()?.day).toBe("2026-11-15");
    expect(cleanup(db, new Date(2026, 10, 15, 12)).dismissals).toBe(0);
    expect(cleanup(db, new Date(2026, 10, 16, 12)).dismissals).toBe(1);
    expect(db.select().from(schema.digestDismissals).all()).toEqual([]);
  });
});

describe("the overview", () => {
  it("counts open conflicts and warnings and shows the top three by severity, then date", async () => {
    clashes();
    // A packed day for Ben on the 3rd (warning, earlier than every conflict but one).
    for (const start of ["07:00", "11:00", "13:00", "15:00"]) {
      event({ date: "2026-11-03", start, end: start.replace(":00", ":30"), title: `Thing ${start}`, person: "Ben" });
    }
    const { weekAhead } = await familyDashboard(db, familyId, TODAY);
    expect(weekAhead.conflicts).toBe(3);
    expect(weekAhead.warnings).toBe(1);
    expect(weekAhead.top.map((i) => [i.kind, i.date])).toEqual([
      ["overlap", "2026-11-03"],
      ["overlap", "2026-11-04"],
      ["overlap", "2026-11-05"],
    ]);
  });
});

// ---- the weekly notification ----

const sent: { channel: Channel; msg: Message }[] = [];
const send = async (channel: Channel, msg: Message) => void sent.push({ channel, msg });
beforeEach(() => {
  sent.length = 0;
});

function channel(name = "Phone") {
  return createChannel(
    db,
    { id: anna.id },
    familyId,
    { name, provider: "PUSHBULLET", token: "tok", target: "", smtpHost: "", smtpPort: 465, smtpUsername: "", smtpFrom: "", enabled: true },
    NOW,
  ).id;
}

const keyOf = (n: number) => Buffer.alloc(32, n);
function fakeRelay() {
  const messages: RelayMessage[] = [];
  const relay: RelayClient = {
    async send(_url, batch) {
      messages.push(...batch);
      return batch.map(() => ({ status: "ok" as const }));
    },
  };
  return { relay, messages };
}
function device(userId: string, n: number) {
  const { row } = createToken(db, { userId, kind: "api", name: `Device ${n}` }, NOW);
  registerDevice(
    db,
    { id: userId },
    row.id,
    { relay: DEFAULT_PUSH_RELAY_URL, relayToken: `r1.${n}`, key: keyOf(n).toString("base64"), platform: "ios" },
    NOW,
  );
}

describe("sendWeeklyDigest", () => {
  it("sends nothing for an empty fortnight, and checks once a day", async () => {
    channel();
    expect(await sendWeeklyDigest(db, familyId, NOW, { send, today: "2026-12-01" })).toBeNull();
    expect(readState(db, familyId, "weekly_digest")).toEqual({ lastSent: "2026-12-01" });
    expect(sent).toEqual([]);
  });

  it("tells the channels every conflict and warning, once a day", async () => {
    channel();
    clashes();
    const res = await sendWeeklyDigest(db, familyId, NOW, { send, today: TODAY });
    expect(res?.channels).toEqual({ sent: 1, failed: 0 });
    expect(sent).toHaveLength(1);
    const msg = sent[0].msg;
    expect(msg.title).toBe("Week ahead: 3 things to check"); // not the unassigned (info) one
    expect(msg.url).toMatch(new RegExp(`/f/${familyId}/digest$`));
    expect(msg.collapseKey).toBe(`digest:${familyId}`);
    const lines = msg.body.split("\n");
    expect(lines[0]).toBe("8 events · 1 birthday");
    expect(lines[1]).toBe("• Tue 3 Nov – Anna: “Dentist” and “Meeting” at the same time (30 min)");
    expect(lines).toHaveLength(4);
    expect(msg.body).not.toContain("Plumber");

    // Once a day; the next day again.
    expect(await sendWeeklyDigest(db, familyId, NOW, { send, today: TODAY })).toBeNull();
    expect(sent).toHaveLength(1);
    await sendWeeklyDigest(db, familyId, NOW, { send, today: "2026-11-03" });
    expect(sent).toHaveLength(2);
  });

  it("pushes each member what concerns them: theirs, the children's and the unassigned ones", async () => {
    channel();
    clashes();
    device(anna.id, 1);
    device(ben.id, 2);
    const relay = fakeRelay();
    const res = await sendWeeklyDigest(db, familyId, NOW, { send, push: relay.relay, today: TODAY });
    expect(res?.users).toHaveLength(2);
    expect(res?.users).toEqual(
      expect.arrayContaining([
        { userId: anna.id, issues: 3, result: { sent: 1, failed: 0 } },
        { userId: ben.id, issues: 3, result: { sent: 1, failed: 0 } },
      ]),
    );
    const bodyOf = (n: number) => {
      const m = relay.messages.find((x) => x.relayToken === `r1.${n}`)!;
      return openPayload(keyOf(n), m.payload);
    };
    const annas = bodyOf(1);
    expect(annas.title).toBe("Week ahead: 3 things to check");
    expect(annas.body).toContain("Dentist");
    expect(annas.body).toContain("Football"); // Max has no account
    expect(annas.body).toContain("Plumber"); // unassigned, info too
    expect(annas.body).not.toContain("Gym"); // Ben's
    expect(annas.event).toBe("weekly_digest");
    expect(annas.path).toBe(`/f/${familyId}/digest`);
    const bens = bodyOf(2);
    expect(bens.body).toContain("Gym");
    expect(bens.body).not.toContain("Dentist");
    // The channel got one message, not one per member.
    expect(sent).toHaveLength(1);
  });

  it("leaves out dismissed issues, and says all clear without any", async () => {
    channel();
    event({ date: "2026-11-03", start: "09:00", end: "10:00", title: "Dentist", person: "Anna" });
    event({ date: "2026-11-03", start: "09:30", end: "10:00", title: "Meeting", person: "Anna" });
    const [issue] = buildDigest(db, familyId, TODAY).issues;
    dismissIssue(db, familyId, issue.key, issue.date, anna.id, NOW);
    away(["2026-11-12", "2026-11-13"]);
    await sendWeeklyDigest(db, familyId, NOW, { send, today: TODAY });
    expect(sent[0].msg.title).toBe("Week ahead: all clear");
    expect(sent[0].msg.body).toBe("2 events · 1 birthday · 2 days away\nNothing clashes in the next two weeks.");
  });

  it("lists ten issues at most, in the family's language", async () => {
    channel();
    db.update(schema.users).set({ preferredLanguage: "de" }).where(eq(schema.users.id, anna.id)).run();
    for (let i = 0; i < 12; i++) {
      const date = `2026-11-${String(2 + i).padStart(2, "0")}`;
      event({ date, start: "09:00", end: "10:00", title: `A${i}`, person: "Anna" });
      event({ date, start: "09:30", end: "10:30", title: `B${i}`, person: "Anna" });
    }
    await sendWeeklyDigest(db, familyId, NOW, { send, today: TODAY });
    const msg = sent[0].msg;
    expect(msg.title).toBe("Wochenvorschau: 12 Dinge zu prüfen");
    const lines = msg.body.split("\n");
    expect(lines[0]).toBe("24 Termine · 1 Geburtstag");
    expect(lines[1]).toBe("• Mo., 2. Nov. – Anna: „A0“ und „B0“ zur selben Zeit (30 Min.)");
    expect(lines).toHaveLength(12);
    expect(lines[11]).toBe("… und 2 weitere in der App");
  });

  it("sends nothing when the family turned it off, and no app push when that is off", async () => {
    const phone = channel();
    clashes();
    device(anna.id, 1);
    const relay = fakeRelay();
    setPref(db, { id: anna.id }, familyId, { event: "weekly_digest", enabled: false, channelIds: null }, NOW);
    expect(await sendWeeklyDigest(db, familyId, NOW, { send, push: relay.relay, today: TODAY })).toBeNull();
    expect(sent).toEqual([]);
    setPref(db, { id: anna.id }, familyId, { event: "weekly_digest", enabled: true, channelIds: [phone], app: false }, NOW);
    const res = await sendWeeklyDigest(db, familyId, NOW, { send, push: relay.relay, today: TODAY });
    expect(res?.users).toEqual([]);
    expect(relay.messages).toEqual([]);
    expect(sent).toHaveLength(1);
  });
});

describe("weeklyDigests (the worker)", () => {
  it("sends on DIGEST_WEEKDAY from DIGEST_HOUR, geocoding first", async () => {
    channel();
    clashes();
    const lookups: string[] = [];
    const lookup: PlaceLookup = async (q) => {
      lookups.push(q);
      return null;
    };
    event({ date: "2026-11-03", start: "12:00", title: "Lunch", location: "Café Kranzler" });
    const env = { DIGEST_WEEKDAY: "0", DIGEST_HOUR: "18" };
    const sunday = (hour: number) => new Date(2026, 10, 1, hour); // local time, a Sunday
    await weeklyDigests(db, sunday(17), { send, lookup, env });
    expect(sent).toEqual([]);
    expect(lookups).toEqual(["Café Kranzler"]); // the daily geocoding runs at any hour
    await weeklyDigests(db, sunday(18), { send, lookup, env });
    expect(sent).toHaveLength(1);
    await weeklyDigests(db, sunday(19), { send, lookup, env });
    expect(sent).toHaveLength(1);
    // Monday: no digest.
    await weeklyDigests(db, new Date(2026, 10, 2, 19), { send, lookup, env });
    expect(sent).toHaveLength(1);
  });

  it("reads its schedule from the environment", () => {
    expect(digestSchedule({})).toEqual({ weekday: 0, hour: 18 });
    expect(digestSchedule({ DIGEST_WEEKDAY: "5", DIGEST_HOUR: "7" })).toEqual({ weekday: 5, hour: 7 });
    expect(digestSchedule({ DIGEST_WEEKDAY: "9", DIGEST_HOUR: "x" })).toEqual({ weekday: 0, hour: 18 });
  });
});

// ---- geocoding ----

describe("refreshPlaces", () => {
  const SCHOOL: Coord = { lat: 52.53, lng: 13.4 };
  function fake(answers: Record<string, Coord | null> = {}) {
    const calls: { query: string; bias: Coord | null }[] = [];
    const lookup: PlaceLookup = async (query, bias) => {
      calls.push({ query, bias });
      return answers[query] ?? null;
    };
    return { lookup, calls };
  }

  it("looks up the new locations of the next 14 days once, biased to home, and caches them", async () => {
    setHome();
    event({ date: "2026-11-03", start: "08:00", title: "School", location: "School" });
    event({ date: "2026-11-04", start: "08:00", title: "School again", location: "  school " });
    event({ date: "2026-11-05", start: "08:00", title: "Nowhere", location: "Atlantis" });
    event({ date: "2026-11-20", start: "08:00", title: "Later", location: "Far future" });
    event({ date: "2026-11-05", start: "10:00", title: "No place" });
    const f = fake({ School: SCHOOL });
    expect(await refreshPlaces(db, familyId, TODAY, { lookup: f.lookup, now: NOW })).toEqual({ looked: 2, found: 1, failed: 0 });
    expect(f.calls).toEqual([
      { query: "Atlantis", bias: { lat: 52.52, lng: 13.405 } },
      { query: "School", bias: { lat: 52.52, lng: 13.405 } },
    ]);
    expect([...cachedPlaces(db, familyId, ["SCHOOL", "Atlantis", "Unknown"])]).toEqual([["school", SCHOOL]]);
    // Cached: nothing to do the next day.
    const again = fake({ School: SCHOOL });
    await refreshPlaces(db, familyId, TODAY, { lookup: again.lookup, now: new Date(NOW.getTime() + DAY_MS) });
    expect(again.calls).toEqual([]);
  });

  it("tries a miss again after 7 days and refreshes a hit after 180, keeping it if it isn't found", async () => {
    event({ date: "2026-11-03", start: "08:00", title: "School", location: "School" });
    event({ date: "2026-11-03", start: "10:00", title: "Nowhere", location: "Atlantis" });
    await refreshPlaces(db, familyId, TODAY, { lookup: fake({ School: SCHOOL }).lookup, now: NOW });
    const at = (days: number) => new Date(NOW.getTime() + days * DAY_MS);

    const six = fake();
    await refreshPlaces(db, familyId, TODAY, { lookup: six.lookup, now: at(6) });
    expect(six.calls).toEqual([]);
    const eight = fake({ Atlantis: { lat: 1, lng: 2 } });
    await refreshPlaces(db, familyId, TODAY, { lookup: eight.lookup, now: at(8) });
    expect(eight.calls.map((c) => c.query)).toEqual(["Atlantis"]);
    expect(cachedPlaces(db, familyId, ["Atlantis"]).get("atlantis")).toEqual({ lat: 1, lng: 2 });

    const later = fake(); // finds nothing
    await refreshPlaces(db, familyId, TODAY, { lookup: later.lookup, now: at(181) });
    expect(later.calls.map((c) => c.query)).toEqual(["School"]); // Atlantis was refreshed on day 8
    expect(cachedPlaces(db, familyId, ["School"]).get("school")).toEqual(SCHOOL);
  });

  it("makes at most 25 look-ups per family in 24 hours", async () => {
    for (let i = 0; i < 30; i++) event({ date: "2026-11-03", start: "08:00", title: `E${i}`, location: `Place ${String(i).padStart(2, "0")}` });
    const first = fake();
    await refreshPlaces(db, familyId, TODAY, { lookup: first.lookup, now: NOW });
    expect(first.calls).toHaveLength(25);
    const soon = fake();
    await refreshPlaces(db, familyId, TODAY, { lookup: soon.lookup, now: new Date(NOW.getTime() + 3_600_000) });
    expect(soon.calls).toEqual([]);
    const tomorrow = fake();
    await refreshPlaces(db, familyId, TODAY, { lookup: tomorrow.lookup, now: new Date(NOW.getTime() + DAY_MS + 1000) });
    expect(tomorrow.calls).toHaveLength(5);
  });

  it("stops at the first failure without caching it, and never throws", async () => {
    event({ date: "2026-11-03", start: "08:00", title: "A", location: "A" });
    event({ date: "2026-11-03", start: "09:00", title: "B", location: "B" });
    const calls: string[] = [];
    const down: PlaceLookup = async (q) => {
      calls.push(q);
      throw new Error("timeout");
    };
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    expect(await refreshPlaces(db, familyId, TODAY, { lookup: down, now: NOW })).toEqual({ looked: 0, found: 0, failed: 1 });
    expect(calls).toEqual(["A"]);
    expect(db.select().from(schema.geoPlaces).all()).toEqual([]);
  });

  it("is off with DIGEST_GEOCODE=0, and the digest then ignores the cache", async () => {
    setHome();
    event({ date: "2026-11-03", start: "09:00", end: "10:00", title: "A", location: "School", person: "Anna" });
    event({ date: "2026-11-03", start: "10:05", end: "11:00", title: "B", location: "Potsdam", person: "Anna" });
    await refreshPlaces(db, familyId, TODAY, {
      lookup: fake({ School: SCHOOL, Potsdam: { lat: 52.39, lng: 13.06 } }).lookup,
      now: NOW,
    });
    expect(buildDigest(db, familyId, TODAY).issues[0]).toMatchObject({ kind: "tight_transfer", severity: "conflict" });

    vi.stubEnv("DIGEST_GEOCODE", "0");
    const off = fake();
    expect(await refreshPlaces(db, familyId, TODAY, { lookup: off.lookup, now: new Date(NOW.getTime() + 400 * DAY_MS) })).toEqual({
      looked: 0,
      found: 0,
      failed: 0,
    });
    expect(off.calls).toEqual([]);
    const digest = buildDigest(db, familyId, TODAY);
    expect(digest.geocoding).toBe(false);
    expect(digest.issues[0]).toMatchObject({ kind: "tight_transfer", severity: "warning", data: { gapMinutes: 5, travelMinutes: null, km: null } });
  });
});

// ---- the assistant ----

describe("check_schedule", () => {
  const ctx = (): ToolContext => ({
    lang: "en",
    calendar: new DrizzleCalendarStore(db),
    finance: new DrizzleFinanceStore(db),
    db,
    familyId,
    net: {} as NetOptions,
    search: null,
    userId: ben.id,
    today: TODAY,
    now: () => NOW,
  });
  const tool = async (args: unknown) => (await runTool("check_schedule", JSON.stringify(args), ctx(), new Set(Object.keys(TOOLS)))) as any;

  it("reads the issues of the next 14 days, or of a range up to 60 days", async () => {
    clashes();
    event({ date: "2026-11-25", start: "09:00", end: "10:00", title: "X", person: "Ben" });
    event({ date: "2026-11-25", start: "09:00", end: "10:00", title: "Y", person: "Ben" });
    const res = await tool({});
    expect(res.ok).toBe(true);
    expect(res.result.from).toBe(TODAY);
    expect(res.result.to).toBe("2026-11-15");
    expect(res.result.issues).toHaveLength(4);
    expect((await tool({ from: "2026-11-20", to: "2026-11-30" })).result.issues.map((i: any) => i.date)).toEqual(["2026-11-25"]);
    expect((await tool({ from: "2026-11-01", to: "2027-01-31" })).result.error).toMatch(/too long/);
    expect((await tool({ from: "nope" })).result.error).toMatch(/YYYY-MM-DD/);
    expect(TOOLS.check_schedule.write).toBeFalsy();
  });
});

// ---- the texts ----

describe("issue sentences", () => {
  const data: Record<IssueKind, Record<string, unknown>> = {
    overlap: { minutes: 30 },
    tight_transfer: { gapMinutes: 10, travelMinutes: 45, km: 35 },
    during_trip: {},
    packed_day: { events: 4, hours: 9.5 },
    long_travel_day: { km: 210, minutes: 160 },
    travel_week: { days: 3, weekStart: "2026-11-02" },
    short_night: { hours: 7.5 },
    away_clash: { away: "Vacation", dates: ["2026-11-10"] },
    drivers_needed: { children: 2, adults: 1 },
    birthday_away: { name: "Mia", age: 8 },
    unassigned_overlap: { minutes: 15 },
  };
  const ev = (title: string) => ({ id: title, occurrence: null, title, date: TODAY, endDate: TODAY, start: "09:00", end: null, location: "" });

  it("exist for every kind in English and German, with every placeholder filled", () => {
    for (const locale of ["en", "de"] as const) {
      const t = translator(locale);
      for (const kind of ISSUE_KINDS) {
        const issue: Issue = {
          key: `${kind}:x`,
          kind,
          severity: "warning",
          date: TODAY,
          people: [
            { id: "a", name: "Anna" },
            { id: "b", name: "Ben" },
          ],
          events: [ev("First"), ev("Second")],
          data: data[kind],
          dismissed: false,
        };
        const variants = kind === "tight_transfer" ? [issue, { ...issue, data: { gapMinutes: 10, travelMinutes: null, km: null } }] : [issue];
        for (const v of variants) {
          const text = issueSentence(v, t, locale);
          expect(text, `${locale} ${kind}`).not.toMatch(/\{\{|notifications\./);
        }
      }
    }
    expect(issueSentence({ ...({} as Issue), kind: "short_night", people: [{ id: "a", name: "Anna" }], events: [ev("Concert"), ev("Flight")], data: { hours: 7.5 } }, translator("de"), "de")).toBe(
      "Anna: nur 7,5 Stunden zwischen „Concert“ und „Flight“",
    );
    expect(issueSentence({ ...({} as Issue), kind: "overlap", people: [{ id: "a", name: "Anna" }, { id: "b", name: "Ben" }, { id: "c", name: "Max" }], events: [ev("A"), ev("B")], data: { minutes: 5 } }, translator("en"), "en")).toBe(
      "Anna, Ben and Max: “A” and “B” at the same time (5 min)",
    );
  });
});
