// Public and school holidays by region: OpenHolidays' answers parsed and matched to a region
// (real responses in tests/fixtures/holidays), the region detected from the home, the sync
// into day entries (types per year, deleted days staying deleted, corrections, turning off,
// moving), the routes, GET /families/{id}'s `holidays` and the family file import starting
// over. Nothing touches the network: the source and the reverse look-up are fakes.

import { readFileSync } from "node:fs";
import { and, eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { EXPORT_FORMAT, EXPORT_VERSION } from "@/lib/calendar/export-file";
import { handleFamily } from "@/lib/calendar/family-routes";
import {
  appliesTo,
  type CachedHoliday,
  holidayDaysIn,
  type HolidayKind,
  type HolidaySource,
  parseCountries,
  parseHolidays,
  parseSubdivisions,
} from "@/lib/calendar/holidays/openholidays";
import { matchRegion, parsePhotonPlace, type Place, regionNames } from "@/lib/calendar/holidays/region";
import { handleHolidays } from "@/lib/calendar/holidays/routes";
import { getHolidaySettings, holidaysByDay, saveHolidaySettings } from "@/lib/calendar/holidays/settings";
import { HolidayRunner, type HolidaysEnv, requestDailyHolidaySyncs, RETRY_MS, syncFamily } from "@/lib/calendar/holidays/sync";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import type { Db } from "@/lib/db";
import * as schema from "@/lib/db/schema";
import { setHomeAddress } from "@/lib/families/home";
import { serverInfo } from "@/lib/server-info";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const fixture = (name: string) => JSON.parse(readFileSync(`tests/fixtures/holidays/${name}`, "utf8"));
const COUNTRIES = parseCountries(fixture("countries.json"));
const DE_SUBDIVISIONS = parseSubdivisions(fixture("de-subdivisions.json"));
const DE_PUBLIC_2026 = parseHolidays(fixture("de-public-2026.json"), "public");
const DE_SCHOOL_2026 = parseHolidays(fixture("de-school-2026.json"), "school");
const DE_PUBLIC_2027: CachedHoliday[] = [
  { start: "2027-01-01", end: "2027-01-01", names: { de: "Neujahr", en: "New Year's Day" }, nationwide: true, subdivisions: [] },
  { start: "2027-01-06", end: "2027-01-06", names: { de: "Heilige Drei Könige", en: "Epiphany" }, nationwide: false, subdivisions: ["DE-BY"] },
];

const TODAY = "2026-11-01";
const DAY_MS = 86_400_000;
const BASE = "http://ohana.test/api/v1";
const MUNICH: Place = { country: "DE", state: "Bayern", county: null, city: "München", district: "Altstadt" };
const HAMBURG: Place = { country: "DE", state: "Hamburg", county: null, city: "Hamburg", district: null };

/** OpenHolidays from the fixtures; `data` per "country|kind|year" can be changed, `fail`
 *  makes every holidays request throw. */
function fakeSource() {
  const data: Record<string, CachedHoliday[]> = {
    "DE|public|2026": DE_PUBLIC_2026,
    "DE|school|2026": DE_SCHOOL_2026,
    "DE|public|2027": DE_PUBLIC_2027,
  };
  const calls: string[] = [];
  const source: HolidaySource & { data: typeof data; calls: string[]; fail: boolean } = {
    data,
    calls,
    fail: false,
    countries: async () => COUNTRIES,
    subdivisions: async (country) => (country === "DE" ? DE_SUBDIVISIONS : []),
    holidays: async (country: string, kind: HolidayKind, year: number) => {
      calls.push(`${country}|${kind}|${year}`);
      if (source.fail) throw new Error("offline");
      return data[`${country}|${kind}|${year}`] ?? [];
    },
  };
  return source;
}

let db: Db;
let familyId: string;
let anna: { id: string };
let ben: { id: string };
let source: ReturnType<typeof fakeSource>;
let place: Place | null;
let env: HolidaysEnv;

beforeEach(() => {
  db = createTestDb();
  anna = makeUser(db, { name: "Anna", email: "anna@test" });
  ben = makeUser(db, { name: "Ben", email: "ben@test" });
  familyId = makeFamily(db, anna.id, [{ userId: ben.id, role: "viewer" }]).id;
  source = fakeSource();
  place = MUNICH;
  env = { source, reverse: async () => place };
});
afterEach(() => vi.unstubAllEnvs());

function setHome(lat = 48.137, lng = 11.575) {
  db.update(schema.families).set({ homeAddress: "Home", homeLat: lat, homeLng: lng }).where(eq(schema.families.id, familyId)).run();
}

function turnOn(set: Partial<typeof schema.holidaySettings.$inferInsert> = {}) {
  saveHolidaySettings(db, familyId, { publicHolidays: true, schoolHolidays: true, requestedAt: NOW, ...set });
}

const store = () => new DrizzleCalendarStore(db, () => NOW);

/** day -> type ids */
async function entries(from = "2026-01-01", to = "2027-12-31") {
  const out: Record<string, string[]> = {};
  for (const r of await store().listEntries(familyId, from, to)) (out[r.day] ??= []).push(r.type_id);
  return out;
}

const recorded = (kind: HolidayKind) =>
  db
    .select({ day: schema.holidayDays.day })
    .from(schema.holidayDays)
    .where(and(eq(schema.holidayDays.familyId, familyId), eq(schema.holidayDays.kind, kind)))
    .all()
    .map((r) => r.day)
    .sort();

describe("OpenHolidays' answers", () => {
  it("keeps full-day holidays of the kind, normalized", () => {
    expect(DE_PUBLIC_2026).toHaveLength(20);
    expect(DE_PUBLIC_2026[1]).toEqual({
      start: "2026-01-06",
      end: "2026-01-06",
      names: { de: "Heilige Drei Könige", en: "Epiphany" },
      nationwide: false,
      subdivisions: ["DE-ST", "DE-BW", "DE-BY"],
    });
    // Switzerland: a nationwide full day, a half day and an optional one; only the first counts.
    const ch = parseHolidays(fixture("ch-public-2026.json"), "public");
    expect(ch).toHaveLength(1);
    expect(ch[0].nationwide).toBe(true);
    // Public holidays aren't school holidays.
    expect(parseHolidays(fixture("de-public-2026.json"), "school")).toEqual([]);
  });

  it("applies a holiday nationwide, to a region and to the municipalities in it", () => {
    const [newYear, epiphany] = DE_PUBLIC_2026;
    const peace = DE_PUBLIC_2026.find((h) => h.subdivisions.includes("DE-BY-AU"))!;
    for (const r of ["DE", "DE-BY", "DE-BY-AU", "DE-HH"]) expect(appliesTo(newYear, r)).toBe(true);
    expect(appliesTo(newYear, "AT", "DE")).toBe(false);
    expect(appliesTo(epiphany, "DE-BY")).toBe(true);
    expect(appliesTo(epiphany, "DE-BY-AU")).toBe(true);
    expect(appliesTo(epiphany, "DE")).toBe(false);
    expect(appliesTo(epiphany, "DE-HH")).toBe(false);
    expect(appliesTo(peace, "DE-BY-AU")).toBe(true);
    expect(appliesTo(peace, "DE-BY")).toBe(false);
  });

  it("lists the days of a region, a holiday over the turn of the year cut to the range", () => {
    const days = holidayDaysIn(DE_SCHOOL_2026, "DE-BY", "DE", "2026-01-01", "2026-01-31");
    expect([...days.keys()].sort()).toEqual(["2026-01-01", "2026-01-02", "2026-01-03", "2026-01-04", "2026-01-05"]);
    expect(days.get("2026-01-05")![0].names.de).toBe("Weihnachtsferien");
  });
});

describe("the region", () => {
  it("is the state's subdivision, a municipality's below it, a city-state's by its city, else the country", () => {
    expect(matchRegion(MUNICH, COUNTRIES, DE_SUBDIVISIONS)).toBe("DE-BY");
    expect(matchRegion({ ...MUNICH, city: "Augsburg" }, COUNTRIES, DE_SUBDIVISIONS)).toBe("DE-BY-AU");
    expect(matchRegion({ ...MUNICH, state: "Bavaria" }, COUNTRIES, DE_SUBDIVISIONS)).toBe("DE-BY");
    expect(matchRegion({ ...MUNICH, state: "baden wurttemberg" }, COUNTRIES, DE_SUBDIVISIONS)).toBe("DE-BW");
    expect(matchRegion({ ...MUNICH, state: "Atlantis" }, COUNTRIES, DE_SUBDIVISIONS)).toBe("DE");
    expect(matchRegion({ ...MUNICH, state: null }, COUNTRIES, DE_SUBDIVISIONS)).toBe("DE");
    expect(matchRegion({ ...MUNICH, state: null, city: "Hamburg", district: "Altstadt" }, COUNTRIES, DE_SUBDIVISIONS)).toBe("DE-HH");
    expect(matchRegion({ ...MUNICH, country: "US" }, COUNTRIES, [])).toBeNull();
  });

  it("reads Photon's place and names the region in every language", () => {
    const body = {
      features: [{ properties: { countrycode: "DE", state: "Bayern", city: "Augsburg", district: "Innenstadt" } }],
    };
    expect(parsePhotonPlace(body)).toEqual({ country: "DE", state: "Bayern", county: null, city: "Augsburg", district: "Innenstadt" });
    expect(parsePhotonPlace({ features: [] })).toBeNull();
    expect(regionNames("DE-BY", COUNTRIES, DE_SUBDIVISIONS)).toEqual({ de: "Bayern, Deutschland", en: "Bavaria, Germany" });
    expect(regionNames("DE-BY-AU", COUNTRIES, DE_SUBDIVISIONS).de).toBe("Augsburg, Bayern, Deutschland");
    expect(regionNames("DE", COUNTRIES, DE_SUBDIVISIONS).en).toBe("Germany");
    expect(regionNames("US", COUNTRIES, [])).toEqual({});
  });
});

describe("the sync", () => {
  it("detects the region, makes the types per year and adds the days", async () => {
    setHome();
    // The user's own holiday type of 2026, which 2027's copies.
    db.update(schema.calEntryTypes)
      .set({ name: "Feiertage" })
      .where(and(eq(schema.calEntryTypes.familyId, familyId), eq(schema.calEntryTypes.id, "holiday")))
      .run();
    turnOn();
    await syncFamily(db, env, familyId, NOW, TODAY);

    const s = getHolidaySettings(db, familyId);
    expect(s).toMatchObject({ region: "DE-BY", regionFrom: "48.137,11.575", syncedRegion: "DE-BY", status: "ok", requestedAt: null });
    expect(s.syncedAt).toEqual(NOW);

    const e = await entries();
    expect(e["2026-01-01"]).toEqual(["holiday", "school-holidays"]); // New Year, Christmas holidays
    expect(e["2026-01-06"]).toEqual(["holiday"]); // Epiphany: Bavaria
    expect(e["2026-03-08"]).toBeUndefined(); // Berlin's
    expect(e["2026-08-08"]).toEqual(["school-holidays"]); // the peace festival is Augsburg's only
    expect(e["2026-11-03"]).toEqual(["school-holidays"]);
    expect(e["2026-10-20"]).toBeUndefined(); // Hamburg's autumn holidays
    expect(e["2027-01-06"]).toEqual(["holiday", "school-holidays"]);
    expect(e["2027-01-08"]).toEqual(["school-holidays"]);
    expect(recorded("public")).toContain("2027-01-01");

    const types = await store().listTypes(familyId);
    const pick = (year: number, id: string) => types.find((t) => t.year === year && t.id === id);
    expect(pick(2027, "holiday")).toMatchObject({ name: "Feiertage", role: "day_off", member_id: anna.id });
    expect(pick(2026, "school-holidays")).toMatchObject({ name: "School holidays", role: "needs_cover", icon: "backpack", member_id: null });
    expect(pick(2026, "school-holidays")!.position).toBe(3); // after the presets
    expect(pick(2027, "school-holidays")).toMatchObject({ name: "School holidays", position: 1 });
    expect(source.calls.sort()).toEqual(["DE|public|2026", "DE|public|2027", "DE|school|2026", "DE|school|2027"]);
  });

  it("names a new school holidays type in the family's language", async () => {
    db.update(schema.users).set({ preferredLanguage: "de" }).where(eq(schema.users.id, anna.id)).run();
    setHome();
    turnOn({ publicHolidays: false });
    await syncFamily(db, env, familyId, NOW, TODAY);
    const types = await store().listTypes(familyId);
    expect(types.find((t) => t.id === "school-holidays")!.name).toBe("Schulferien");
  });

  it("uses the cache for a week and keeps an old copy when the source fails", async () => {
    setHome();
    turnOn();
    await syncFamily(db, env, familyId, NOW, TODAY);
    source.calls.length = 0;
    turnOn();
    await syncFamily(db, env, familyId, new Date(NOW.getTime() + DAY_MS), TODAY);
    expect(source.calls).toEqual([]);
    source.fail = true;
    turnOn();
    await syncFamily(db, env, familyId, new Date(NOW.getTime() + 8 * DAY_MS), "2026-11-09");
    expect(source.calls).toHaveLength(4);
    expect(getHolidaySettings(db, familyId).status).toBe("ok");
  });

  it("doesn't add a day again that the user deleted", async () => {
    setHome();
    turnOn();
    await syncFamily(db, env, familyId, NOW, TODAY);
    await store().removeEntries(familyId, ["2026-11-18"]);
    turnOn();
    await syncFamily(db, env, familyId, NOW, TODAY);
    expect((await entries())["2026-11-18"]).toBeUndefined();
    expect((await entries())["2026-11-17"]).toBeUndefined();
    expect((await entries())["2026-11-04"]).toEqual(["school-holidays"]);
  });

  it("leaves a holiday the user entered themselves alone", async () => {
    await store().addEntries(familyId, [{ day: "2026-12-25", type_id: "holiday" }]);
    setHome();
    turnOn();
    await syncFamily(db, env, familyId, NOW, TODAY);
    expect(recorded("public")).not.toContain("2026-12-25");
    expect(recorded("public")).toContain("2026-12-26");
    saveHolidaySettings(db, familyId, { publicHolidays: false, requestedAt: NOW });
    await syncFamily(db, env, familyId, NOW, TODAY);
    const e = await entries();
    expect(e["2026-12-25"]).toEqual(["holiday", "school-holidays"]);
    expect(e["2026-12-26"]).toEqual(["school-holidays"]);
  });

  it("removes a future day the source no longer lists, keeps the past", async () => {
    setHome();
    turnOn();
    await syncFamily(db, env, familyId, NOW, TODAY);
    // Corrected: no Christmas holidays, and no summer holidays (past).
    source.data["DE|school|2026"] = DE_SCHOOL_2026.filter((h) => !["Weihnachtsferien", "Sommerferien"].includes(h.names.de) || h.start < "2026-01-01");
    const later = new Date(NOW.getTime() + 8 * DAY_MS);
    turnOn();
    await syncFamily(db, env, familyId, later, "2026-11-09");
    const e = await entries();
    expect(e["2026-12-24"]).toBeUndefined();
    expect(e["2026-12-28"]).toBeUndefined();
    expect(e["2027-01-05"]).toBeUndefined();
    expect(e["2026-08-10"]).toEqual(["school-holidays"]);
    expect(recorded("school")).not.toContain("2026-12-28");
    expect(recorded("school")).toContain("2026-08-10");
  });

  it("takes back the future days of a kind turned off, the past stays", async () => {
    setHome();
    turnOn();
    await syncFamily(db, env, familyId, NOW, TODAY);
    saveHolidaySettings(db, familyId, { schoolHolidays: false, requestedAt: NOW });
    await syncFamily(db, env, familyId, NOW, TODAY);
    const e = await entries();
    expect(e["2026-11-03"]).toBeUndefined();
    expect(e["2026-12-25"]).toEqual(["holiday"]);
    expect(e["2026-08-10"]).toEqual(["school-holidays"]);
    expect(recorded("school").every((d) => d < TODAY)).toBe(true);
  });

  it("moves with the home: the old region's future days go, the new one's come from today on", async () => {
    setHome();
    turnOn();
    await syncFamily(db, env, familyId, NOW, TODAY);
    place = HAMBURG;
    setHome(53.55, 10);
    turnOn();
    await syncFamily(db, env, familyId, NOW, TODAY);
    const s = getHolidaySettings(db, familyId);
    expect(s).toMatchObject({ region: "DE-HH", syncedRegion: "DE-HH", importFrom: TODAY, status: "ok" });
    const e = await entries();
    expect(e["2026-01-06"]).toEqual(["holiday"]); // Bavaria's, past: stays
    expect(e["2026-11-03"]).toBeUndefined(); // Bavaria's autumn holidays
    expect(e["2026-10-20"]).toBeUndefined(); // Hamburg's, before the move
    expect(e["2026-12-21"]).toEqual(["school-holidays"]); // Hamburg's Christmas holidays
    expect(e["2027-01-06"]).toBeUndefined(); // Epiphany: Bavaria only
    expect(e["2027-01-01"]).toEqual(["holiday", "school-holidays"]);
  });

  it("says when there is no home or the country isn't supported, and imports nothing", async () => {
    turnOn();
    await syncFamily(db, env, familyId, NOW, TODAY);
    expect(getHolidaySettings(db, familyId)).toMatchObject({ status: "no_address", region: null, requestedAt: null });
    setHome(40.7, -74);
    place = { country: "US", state: "New York", county: null, city: "New York", district: null };
    turnOn();
    await syncFamily(db, env, familyId, NOW, TODAY);
    expect(getHolidaySettings(db, familyId)).toMatchObject({ status: "unsupported", region: null });
    expect(await entries()).toEqual({});
  });

  it("marks a failed sync and tries again later", async () => {
    setHome();
    turnOn();
    source.fail = true;
    await syncFamily(db, env, familyId, NOW, TODAY);
    const s = getHolidaySettings(db, familyId);
    expect(s.status).toBe("failed");
    expect(s.requestedAt!.getTime()).toBe(NOW.getTime() + RETRY_MS);
  });

  it("is asked for once a day and run by the worker's runner", async () => {
    setHome();
    turnOn({ requestedAt: null, syncedAt: new Date(NOW.getTime() - 2 * DAY_MS) });
    expect(requestDailyHolidaySyncs(db, NOW)).toBe(1);
    expect(requestDailyHolidaySyncs(db, NOW)).toBe(0);
    const runner = new HolidayRunner(db, env);
    expect(runner.tick(new Date(NOW.getTime() + 1000))).toBe(true);
    expect(runner.tick(new Date(NOW.getTime() + 1000))).toBe(false); // one round at a time
    await runner.idle();
    expect(getHolidaySettings(db, familyId)).toMatchObject({ status: "ok", requestedAt: null });
    expect(runner.tick(new Date(NOW.getTime() + 2000))).toBe(false);
    expect(new HolidayRunner(db, { ...env, source: null }).tick(NOW)).toBe(false);
  });

  it("is asked for when the home address changes", () => {
    turnOn({ requestedAt: null });
    setHomeAddress(db, { id: anna.id }, familyId, { address: "Marienplatz", lat: 48.1, lng: 11.5 }, NOW);
    expect(getHolidaySettings(db, familyId).requestedAt).toEqual(NOW);
  });
});

// ---- the routes ----

type Res = { status: number; data: any };

function api() {
  const handler = createFamilyApi([handleFamily, handleHolidays(env)], { db, appUrl: "http://ohana.test", now: () => NOW });
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

describe("the routes", () => {
  it("answers the settings, editors change them", async () => {
    const as = api();
    expect((await as(ben.id)("GET", "/holidays")).data).toEqual({
      public: false,
      school: false,
      auto: true,
      region: null,
      status: "off",
      syncedAt: null,
    });
    expect((await as(ben.id)("PUT", "/holidays", { public: true })).status).toBe(403);
    expect((await as(anna.id)("PUT", "/holidays", { public: "yes" })).status).toBe(400);
    expect((await as(anna.id)("PUT", "/holidays", { region: "bavaria!" })).status).toBe(400);

    setHome();
    const put = await as(anna.id)("PUT", "/holidays", { public: true });
    expect(put.status).toBe(200);
    // The region is detected at once; the import waits for the worker.
    expect(put.data).toEqual({ public: true, school: false, auto: true, region: { code: "DE-BY", name: "Bavaria, Germany" }, status: "pending", syncedAt: null });
    db.update(schema.users).set({ preferredLanguage: "de" }).where(eq(schema.users.id, ben.id)).run();
    expect((await as(ben.id)("GET", "/holidays")).data.region).toEqual({ code: "DE-BY", name: "Bayern, Deutschland" });

    const fixed = await as(anna.id)("PUT", "/holidays", { region: "de-hh" });
    expect(fixed.data).toMatchObject({ auto: false, region: { code: "DE-HH", name: "Hamburg, Germany" } });
    const auto = await as(anna.id)("PUT", "/holidays", { region: null });
    expect(auto.data).toMatchObject({ auto: true, region: { code: "DE-BY" } });

    await syncFamily(db, env, familyId, NOW, TODAY);
    expect((await as(anna.id)("GET", "/holidays")).data).toMatchObject({ status: "ok", syncedAt: NOW.toISOString() });
  });

  it("takes back the future days at once when a kind is turned off", async () => {
    setHome();
    turnOn();
    await syncFamily(db, env, familyId, NOW, TODAY);
    expect((await entries())["2026-11-03"]).toEqual(["school-holidays"]);
    await api()(anna.id)("PUT", "/holidays", { school: false });
    expect((await entries())["2026-11-03"]).toBeUndefined();
  });

  it("lists countries and regions in the caller's language", async () => {
    const as = api();
    const countries = (await as(anna.id)("GET", "/holidays/regions")).data;
    expect(countries.find((c: { code: string }) => c.code === "DE")).toEqual({ code: "DE", name: "Germany" });
    const regions = (await as(ben.id)("GET", "/holidays/regions?country=de")).data;
    expect(regions).toHaveLength(16);
    expect(regions.find((r: { code: string }) => r.code === "DE-BY")).toEqual({
      code: "DE-BY",
      name: "Bavaria",
      children: [{ code: "DE-BY-AU", name: "Augsburg" }],
    });
    expect((await as(anna.id)("GET", "/holidays/regions?country=Germany")).status).toBe(400);
    source.countries = async () => {
      throw new Error("offline");
    };
    const down = await as(anna.id)("GET", "/holidays/regions");
    expect(down.status).toBe(502);
    expect(down.data.error).toBeTruthy();
  });

  it("puts the region's holidays of the kinds that are on into GET /families/{id}", async () => {
    setHome();
    turnOn();
    await syncFamily(db, env, familyId, NOW, TODAY);
    const res = await api()(anna.id)("GET", "?from=2026-12-20&to=2026-12-31");
    expect(res.data.holidays["2026-12-25"]).toEqual([
      { name: "Christmas Day", kind: "public" },
      { name: "Christmas Holidays", kind: "school" },
    ]);
    expect(res.data.holidays["2026-12-20"]).toBeUndefined();
    expect(Object.keys(res.data.holidays)).toHaveLength(8); // 24th to 31st
    saveHolidaySettings(db, familyId, { schoolHolidays: false });
    db.update(schema.users).set({ preferredLanguage: "de" }).where(eq(schema.users.id, anna.id)).run();
    const de = await api()(anna.id)("GET", "?from=2026-12-20&to=2026-12-31");
    expect(de.data.holidays).toEqual({
      "2026-12-25": [{ name: "1. Weihnachtsfeiertag", kind: "public" }],
      "2026-12-26": [{ name: "2. Weihnachtsfeiertag", kind: "public" }],
    });
    vi.stubEnv("HOLIDAYS_URL", "");
    expect(holidaysByDay(db, familyId, { from: "2026-12-20", to: "2026-12-31" }, "en", false)).toEqual({});
    expect((await api()(anna.id)("GET", "?from=2026-12-20&to=2026-12-31")).data.holidays).toEqual({});
  });

  it("starts over after the family file replaced the entries", async () => {
    setHome();
    turnOn();
    await syncFamily(db, env, familyId, NOW, TODAY);
    expect(recorded("public").length).toBeGreaterThan(0);
    const res = await api()(anna.id)("POST", "/import", {
      format: EXPORT_FORMAT,
      version: EXPORT_VERSION,
      name: "Krug",
      types: [{ id: "holiday", year: 2026, name: "Holiday", role: "day_off", position: 0 }],
      entries: {},
      notes: {},
    });
    expect(res.status).toBe(200);
    expect(recorded("public")).toEqual([]);
    expect(getHolidaySettings(db, familyId).requestedAt).toEqual(NOW);
    await syncFamily(db, env, familyId, NOW, TODAY);
    expect((await entries())["2026-12-25"]).toEqual(["holiday", "school-holidays"]);
  });
});

describe("the server info", () => {
  it("says whether holidays can be imported", () => {
    expect(serverInfo({}).holidays).toBe(true);
    expect(serverInfo({ HOLIDAYS_URL: "" }).holidays).toBe(false);
  });
});
