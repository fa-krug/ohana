// Phase 11, the week ahead: the pure parts. Who an event is for (attribution), the travel
// estimate, and every check of lib/digest/checks.ts with the cases it must not report.

import { describe, expect, it } from "vitest";
import { type FamilyPerson, attributePeople, isAdult, isChild, splitNames } from "@/lib/digest/attribution";
import {
  type CheckEvent,
  type CheckInput,
  type Issue,
  checkSchedule,
  issueKey,
  LONG_TRAVEL_MINUTES,
  SHORT_NIGHT_HOURS,
} from "@/lib/digest/checks";
import { type Coord, distanceKm, estimateTravel, placeKey, roadKm, roundKm, travelMinutesFor } from "@/lib/digest/travel";

// ---- attribution ----

const anna: FamilyPerson = { id: "anna", name: "Anna Krug", account: true, birthday: "1985-03-10" };
const ben: FamilyPerson = { id: "ben", name: "Ben", account: true, birthday: null };
const max: FamilyPerson = { id: "max", name: "Max", account: false, birthday: "2016-05-01" };
const mia: FamilyPerson = { id: "mia", name: "Mia", account: false, birthday: "2018-11-05" };
const PEOPLE = [anna, ben, max, mia];

describe("attribution", () => {
  it("splits a person text into names", () => {
    expect(splitNames("Anna & Max, Ben + Mia / Oma")).toEqual(["anna", "max", "ben", "mia", "oma"]);
    expect(splitNames("Max and Mia und Ben")).toEqual(["max", "mia", "ben"]);
    expect(splitNames("Alexandra")).toEqual(["alexandra"]); // "and" only as a word
    expect(splitNames("  ")).toEqual([]);
  });

  it("matches whole names and unique first names, ignoring case and accents", () => {
    expect(attributePeople("anna krug", PEOPLE)).toEqual(["anna"]);
    expect(attributePeople("ANNA", PEOPLE)).toEqual(["anna"]); // the only Anna
    expect(attributePeople("Max & Ánna", PEOPLE)).toEqual(["anna", "max"]); // the family's order
    expect(attributePeople("Mia und Oma", PEOPLE)).toEqual(["mia"]); // Oma matches nobody
    expect(attributePeople("Oma", PEOPLE)).toEqual([]);
    expect(attributePeople("", PEOPLE)).toEqual([]);
    expect(attributePeople("Léa", [{ id: "lea", name: "Lea", account: false, birthday: null }])).toEqual(["lea"]);
  });

  it("doesn't guess between two people with the same first name", () => {
    const two: FamilyPerson[] = [
      { id: "m1", name: "Max Müller", account: false, birthday: null },
      { id: "m2", name: "Max Meier", account: false, birthday: null },
    ];
    expect(attributePeople("Max", two)).toEqual([]);
    expect(attributePeople("max muller", two)).toEqual(["m1"]);
  });

  it("tells children (under 14) and adults (18+, or accounts without a birthday)", () => {
    const p = (birthday: string | null, account = false): FamilyPerson => ({ id: "x", name: "X", account, birthday });
    expect(isChild(p("2012-11-03"), "2026-11-02")).toBe(true); // 13, turns 14 tomorrow
    expect(isChild(p("2012-11-02"), "2026-11-02")).toBe(false); // 14 today
    expect(isAdult(p("2008-11-03"), "2026-11-02")).toBe(false); // 17
    expect(isAdult(p("2008-11-02"), "2026-11-02")).toBe(true); // 18
    expect(isAdult(p(null, true), "2026-11-02")).toBe(true);
    expect(isAdult(p(null, false), "2026-11-02")).toBe(false);
    expect(isChild(p(null, false), "2026-11-02")).toBe(false);
  });
});

// ---- travel ----

describe("travel estimate", () => {
  it("is the straight line × 1.3 at 30 / 60 / 90 km/h plus 10 minutes", () => {
    expect(travelMinutesFor(0)).toBe(10);
    expect(travelMinutesFor(10)).toBeCloseTo(13 / 30 * 60 + 10); // 13 road km: town
    expect(travelMinutesFor(20)).toBeCloseTo(26 / 60 * 60 + 10); // 26 road km: country roads
    expect(travelMinutesFor(100)).toBeCloseTo(130 / 90 * 60 + 10); // motorway
    expect(roadKm(100)).toBeCloseTo(130);
    const berlin = { lat: 52.52, lng: 13.405 };
    const hamburg = { lat: 53.55, lng: 9.99 };
    const est = estimateTravel(berlin, hamburg);
    expect(est.km).toBeGreaterThan(250);
    expect(est.km).toBeLessThan(260);
    expect(est.roadKm).toBeCloseTo(est.km * 1.3);
    expect(est.minutes).toBeCloseTo(travelMinutesFor(est.km));
  });

  it("rounds km to whole km, one decimal under 10, and keys places by their text", () => {
    expect(roundKm(9.94)).toBe(9.9);
    expect(roundKm(12.4)).toBe(12);
    expect(placeKey("  Main   St 1 ")).toBe("main st 1");
    expect(placeKey("Müller")).not.toBe(placeKey("Muller")); // accents tell places apart
    expect(placeKey("")).toBe("");
  });
});

// ---- the checks ----

const HOME: Coord = { lat: 52.52, lng: 13.405 }; // Berlin
const PLACES: Record<string, Coord> = {
  school: { lat: 52.53, lng: 13.4 }, // ~1 km from home
  "school annex": { lat: 52.5301, lng: 13.4001 }, // the same place, other text
  pool: { lat: 52.5, lng: 13.3 }, // ~7 km
  potsdam: { lat: 52.39, lng: 13.06 }, // ~27 km
  leipzig: { lat: 51.34, lng: 12.37 }, // ~150 km
  hamburg: { lat: 53.55, lng: 9.99 }, // ~255 km
  munich: { lat: 48.14, lng: 11.58 }, // ~500 km
  "munich messe": { lat: 48.135, lng: 11.7 }, // ~9 km from munich
};

let n = 0;
function ev(e: Partial<CheckEvent> & { date: string }): CheckEvent {
  return {
    id: e.id ?? `e${++n}`,
    occurrence: e.occurrence ?? null,
    date: e.date,
    endDate: e.endDate ?? e.date,
    start: e.start ?? null,
    end: e.end ?? null,
    title: e.title ?? "Event",
    location: e.location ?? "",
    person: e.person ?? "",
  };
}

function check(events: CheckEvent[], over: Partial<CheckInput> = {}): Issue[] {
  return checkSchedule({
    from: "2026-11-02",
    to: "2026-11-15",
    events,
    people: PEOPLE,
    away: new Map(),
    home: HOME,
    places: new Map(Object.entries(PLACES)),
    ...over,
  });
}
const ofKind = (issues: Issue[], kind: Issue["kind"]) => issues.filter((i) => i.kind === kind);

describe("overlap", () => {
  it("is one person with two timed events at the same time", () => {
    const a = ev({ id: "a", date: "2026-11-03", start: "09:00", end: "10:00", title: "Dentist", person: "Anna" });
    const b = ev({ id: "b", date: "2026-11-03", start: "09:30", end: "11:00", title: "Meeting", person: "anna krug" });
    const [issue] = ofKind(check([a, b]), "overlap");
    expect(issue).toEqual({
      key: "overlap:a,b",
      kind: "overlap",
      severity: "conflict",
      date: "2026-11-03",
      people: [{ id: "anna", name: "Anna Krug" }],
      events: [
        { id: "a", occurrence: null, title: "Dentist", date: "2026-11-03", endDate: "2026-11-03", start: "09:00", end: "10:00", location: "" },
        { id: "b", occurrence: null, title: "Meeting", date: "2026-11-03", endDate: "2026-11-03", start: "09:30", end: "11:00", location: "" },
      ],
      data: { minutes: 30 },
      dismissed: false,
    });
  });

  it("counts an event without an end as an hour, and two people sharing both events once", () => {
    const issues = check([
      ev({ id: "a", date: "2026-11-03", start: "09:00", person: "Anna & Ben" }),
      ev({ id: "b", date: "2026-11-03", start: "09:45", person: "Ben, Anna" }),
    ]);
    expect(ofKind(issues, "overlap")).toHaveLength(1);
    expect(ofKind(issues, "overlap")[0].people.map((p) => p.id)).toEqual(["anna", "ben"]);
    expect(ofKind(issues, "overlap")[0].data).toEqual({ minutes: 15 });
  });

  it("keys repeating events by occurrence", () => {
    const issues = check([
      ev({ id: "s", occurrence: "2026-11-03", date: "2026-11-03", start: "09:00", end: "10:00", person: "Ben" }),
      ev({ id: "t", date: "2026-11-03", start: "09:30", end: "10:00", person: "Ben" }),
    ]);
    expect(ofKind(issues, "overlap")[0].key).toBe("overlap:s@2026-11-03,t");
  });

  it("isn't back-to-back events, other people's, all-day ones or events before the range", () => {
    const issues = check([
      ev({ date: "2026-11-03", start: "09:00", end: "10:00", person: "Anna" }),
      ev({ date: "2026-11-03", start: "10:00", end: "11:00", person: "Anna" }),
      ev({ date: "2026-11-03", start: "10:30", end: "11:30", person: "Ben" }),
      ev({ date: "2026-11-03", person: "Ben" }),
      ev({ date: "2026-11-01", start: "09:00", end: "10:00", person: "Max" }),
      ev({ date: "2026-11-01", start: "09:00", end: "10:00", person: "Max" }),
    ]);
    expect(ofKind(issues, "overlap")).toEqual([]);
  });
});

describe("unassigned_overlap", () => {
  it("is two timed events for nobody in particular at the same time (info)", () => {
    const issues = check([
      ev({ id: "a", date: "2026-11-04", start: "18:00", end: "19:00", title: "Parents' evening" }),
      ev({ id: "b", date: "2026-11-04", start: "18:30", end: "20:00", title: "Plumber", person: "Grandpa" }),
    ]);
    expect(ofKind(issues, "unassigned_overlap")).toEqual([
      expect.objectContaining({ key: "unassigned_overlap:a,b", severity: "info", people: [], data: { minutes: 30 } }),
    ]);
  });

  it("isn't an assigned event against an unassigned one", () => {
    const issues = check([
      ev({ date: "2026-11-04", start: "18:00", end: "19:00" }),
      ev({ date: "2026-11-04", start: "18:30", end: "20:00", person: "Ben" }),
    ]);
    expect(issues).toEqual([]);
  });
});

describe("tight_transfer", () => {
  it("is less time between two places than the drive takes (conflict, with the estimate)", () => {
    const a = ev({ id: "a", date: "2026-11-03", start: "09:00", end: "10:00", location: "School", person: "Anna" });
    const b = ev({ id: "b", date: "2026-11-03", start: "10:15", end: "11:00", location: "Potsdam", person: "Anna" });
    const km = distanceKm(PLACES.school, PLACES.potsdam);
    expect(ofKind(check([a, b]), "tight_transfer")).toEqual([
      expect.objectContaining({
        key: "tight_transfer:a,b",
        severity: "conflict",
        date: "2026-11-03",
        data: { gapMinutes: 15, travelMinutes: Math.round(travelMinutesFor(km)), km: roundKm(roadKm(km)) },
      }),
    ]);
    // Enough time: nothing.
    const later = { ...b, start: "11:00", end: "12:00" };
    expect(ofKind(check([a, later]), "tight_transfer")).toEqual([]);
  });

  it("without coordinates, is a gap under 15 minutes between different places (warning)", () => {
    const a = ev({ id: "a", date: "2026-11-03", start: "09:00", end: "10:00", location: "Gym", person: "Ben" });
    const b = ev({ id: "b", date: "2026-11-03", start: "10:10", end: "11:00", location: "Office", person: "Ben" });
    expect(ofKind(check([a, b]), "tight_transfer")).toEqual([
      expect.objectContaining({ severity: "warning", data: { gapMinutes: 10, travelMinutes: null, km: null } }),
    ]);
    // Without geocoding (no places) the same holds for known places.
    const c = { ...a, location: "School" };
    const d = { ...b, location: "Potsdam" };
    expect(ofKind(check([c, d], { places: new Map() }), "tight_transfer")[0].severity).toBe("warning");
    expect(ofKind(check([a, { ...b, start: "10:20" }]), "tight_transfer")).toEqual([]);
  });

  it("isn't the same place (by text or coordinates), an unknown place or an overlap", () => {
    const at = (location: string, start: string, end: string) => ev({ date: "2026-11-03", start, end, location, person: "Ben" });
    expect(ofKind(check([at("Gym", "09:00", "10:00"), at(" gym ", "10:00", "11:00")]), "tight_transfer")).toEqual([]);
    expect(ofKind(check([at("School", "09:00", "10:00"), at("School annex", "10:00", "11:00")]), "tight_transfer")).toEqual([]);
    expect(ofKind(check([at("Gym", "09:00", "10:00"), at("", "10:00", "11:00")]), "tight_transfer")).toEqual([]);
    expect(ofKind(check([at("Gym", "09:00", "10:30"), at("Office", "10:00", "11:00")]), "tight_transfer")).toEqual([]);
  });
});

describe("during_trip", () => {
  const trip = ev({ id: "trip", date: "2026-11-04", endDate: "2026-11-06", title: "Conference", location: "Munich", person: "Ben" });

  it("is a timed event elsewhere while on a trip", () => {
    const home = ev({ id: "x", date: "2026-11-05", start: "10:00", end: "11:00", title: "Parents' evening", location: "School", person: "Ben" });
    expect(ofKind(check([trip, home]), "during_trip")).toEqual([
      expect.objectContaining({
        key: "during_trip:trip,x",
        severity: "warning",
        date: "2026-11-05",
        people: [{ id: "ben", name: "Ben" }],
        data: {},
        events: [expect.objectContaining({ id: "trip" }), expect.objectContaining({ id: "x" })],
      }),
    ]);
  });

  it("isn't an event at the trip's place, without a location, after the trip or someone else's", () => {
    const issues = check([
      trip,
      ev({ date: "2026-11-05", start: "10:00", end: "11:00", location: "Munich Messe", person: "Ben" }),
      ev({ date: "2026-11-05", start: "12:00", end: "13:00", person: "Ben" }),
      ev({ date: "2026-11-07", start: "10:00", end: "11:00", location: "School", person: "Ben" }),
      ev({ date: "2026-11-05", start: "10:00", end: "11:00", location: "School", person: "Anna" }),
    ]);
    expect(ofKind(issues, "during_trip")).toEqual([]);
  });

  it("compares the text when there are no coordinates", () => {
    const rome = ev({ id: "rome", date: "2026-11-04", endDate: "2026-11-08", location: "Rome", person: "Anna" });
    const colosseum = ev({ date: "2026-11-05", start: "10:00", end: "12:00", location: "Colosseum, Rome", person: "Anna" });
    const office = ev({ id: "office", date: "2026-11-06", start: "10:00", end: "12:00", location: "Office", person: "Anna" });
    expect(ofKind(check([rome, colosseum, office]), "during_trip").map((i) => i.key)).toEqual(["during_trip:office,rome"]);
  });
});

describe("packed_day", () => {
  const at = (start: string, end: string) => ev({ date: "2026-11-06", start, end, person: "Max" });

  it("is 4 or more timed events in a day", () => {
    const issues = check([at("08:00", "09:00"), at("10:00", "11:00"), at("14:00", "15:00"), at("16:00", "16:30")]);
    expect(ofKind(issues, "packed_day")).toEqual([
      expect.objectContaining({ severity: "warning", date: "2026-11-06", data: { events: 4, hours: 3.5 }, people: [{ id: "max", name: "Max" }] }),
    ]);
  });

  it("is 9 or more hours booked (overlaps counted once)", () => {
    expect(ofKind(check([at("08:00", "17:30")]), "packed_day")[0].data).toEqual({ events: 1, hours: 9.5 });
    expect(ofKind(check([at("08:00", "13:00"), at("12:00", "16:00")]), "packed_day")).toEqual([]); // 8 hours
    expect(ofKind(check([at("08:00", "10:00"), at("11:00", "12:00"), at("13:00", "14:00")]), "packed_day")).toEqual([]);
  });
});

describe("long_travel_day", () => {
  it("is home → events → home of 150 minutes or 200 km and more", () => {
    const issues = check([ev({ id: "h", date: "2026-11-05", start: "10:00", end: "15:00", location: "Hamburg", person: "Anna" })]);
    const km = distanceKm(HOME, PLACES.hamburg);
    expect(ofKind(issues, "long_travel_day")).toEqual([
      expect.objectContaining({
        key: "long_travel_day:h",
        severity: "warning",
        data: { km: roundKm(2 * roadKm(km)), minutes: Math.round(2 * travelMinutesFor(km)) },
      }),
    ]);
    expect(2 * travelMinutesFor(km)).toBeGreaterThan(LONG_TRAVEL_MINUTES);
  });

  it("adds up the legs of a day (10 minutes each)", () => {
    const at = (start: string, location: string) => ev({ date: "2026-11-05", start, end: start.replace(/:00$/, ":30"), location, person: "Ben" });
    const leg = (a: Coord, b: Coord) => travelMinutesFor(distanceKm(a, b));
    // home → Potsdam → Pool → Potsdam → home: about 164 minutes, 125 road km.
    const long = check([at("08:00", "Potsdam"), at("11:00", "Pool"), at("14:00", "Potsdam")]);
    const total = 2 * leg(HOME, PLACES.potsdam) + 2 * leg(PLACES.potsdam, PLACES.pool);
    expect(total).toBeGreaterThan(LONG_TRAVEL_MINUTES);
    expect(ofKind(long, "long_travel_day")[0].data).toEqual({
      km: roundKm(roadKm(2 * distanceKm(HOME, PLACES.potsdam) + 2 * distanceKm(PLACES.potsdam, PLACES.pool))),
      minutes: Math.round(total),
    });
    // home → Potsdam → Pool → School → home: about 125 minutes.
    expect(ofKind(check([at("08:00", "Potsdam"), at("11:00", "Pool"), at("14:00", "School")]), "long_travel_day")).toEqual([]);
  });

  it("isn't a short trip, a day without a home or a day on a trip", () => {
    expect(ofKind(check([ev({ date: "2026-11-05", start: "10:00", location: "Potsdam", person: "Anna" })]), "long_travel_day")).toEqual([]);
    const far = ev({ date: "2026-11-05", start: "10:00", location: "Hamburg", person: "Anna" });
    expect(ofKind(check([far], { home: null }), "long_travel_day")).toEqual([]);
    const trip = ev({ date: "2026-11-04", endDate: "2026-11-06", location: "Hamburg", person: "Anna" });
    expect(ofKind(check([trip, far]), "long_travel_day")).toEqual([]);
  });
});

describe("travel_week", () => {
  const far = (date: string) => ev({ id: `l${date.slice(8)}`, date, start: "09:00", end: "10:00", location: "Leipzig", person: "Ben" });

  it("is 3 or more days of a week with an event 50 km or more from home", () => {
    const issues = check([far("2026-11-02"), far("2026-11-04"), far("2026-11-06")]);
    expect(ofKind(issues, "travel_week")).toEqual([
      expect.objectContaining({
        key: "travel_week:l02,l04,l06",
        date: "2026-11-02",
        severity: "warning",
        data: { days: 3, weekStart: "2026-11-02" },
      }),
    ]);
  });

  it("counts weeks Monday to Sunday, and not trips or near events", () => {
    expect(ofKind(check([far("2026-11-02"), far("2026-11-04")]), "travel_week")).toEqual([]);
    expect(ofKind(check([far("2026-11-08"), far("2026-11-09"), far("2026-11-10")]), "travel_week")).toEqual([]); // Sun + Mon, Tue
    const near = (date: string) => ev({ date, start: "09:00", location: "Potsdam", person: "Ben" });
    expect(ofKind(check([near("2026-11-02"), near("2026-11-03"), near("2026-11-04")]), "travel_week")).toEqual([]);
    const trip = ev({ date: "2026-11-02", endDate: "2026-11-06", location: "Leipzig", person: "Ben" });
    expect(ofKind(check([trip, far("2026-11-02"), far("2026-11-04"), far("2026-11-06")]), "travel_week")).toEqual([]);
  });
});

describe("short_night", () => {
  it("is less than 9 hours between the last event of a day and the first of the next", () => {
    const late = ev({ id: "late", date: "2026-11-03", start: "20:00", end: "23:00", person: "Anna" });
    const early = ev({ id: "early", date: "2026-11-04", start: "06:30", end: "08:00", person: "Anna" });
    expect(ofKind(check([late, early]), "short_night")).toEqual([
      expect.objectContaining({ key: "short_night:early,late", date: "2026-11-03", data: { hours: 7.5 } }),
    ]);
    expect(ofKind(check([late, { ...early, start: "08:00", end: "09:00" }]), "short_night")).toEqual([]); // 9 hours
  });

  it("counts the drive home and back", () => {
    const travel = travelMinutesFor(distanceKm(HOME, PLACES.potsdam));
    const late = ev({ date: "2026-11-03", start: "20:00", end: "22:00", location: "Potsdam", person: "Ben" });
    const early = ev({ date: "2026-11-04", start: "07:30", end: "08:00", location: "Potsdam", person: "Ben" });
    const hours = (9.5 * 60 - 2 * travel) / 60;
    expect(hours).toBeLessThan(SHORT_NIGHT_HOURS);
    expect(ofKind(check([late, early]), "short_night")[0].data).toEqual({ hours: Math.round(hours * 10) / 10 });
    // Without coordinates, 9.5 hours are enough.
    expect(ofKind(check([late, early], { places: new Map() }), "short_night")).toEqual([]);
  });
});

describe("away_clash", () => {
  const away = new Map([
    ["2026-11-10", ["Vacation"]],
    ["2026-11-11", ["Vacation"]],
    ["2026-11-12", ["Vacation"]],
  ]);

  it("is a timed event near home or without a location while away, one issue per series", () => {
    const football = (d: string) =>
      ev({ id: "foot", occurrence: d, date: d, start: "17:00", end: "18:00", title: "Football", location: "Pool", person: "Max" });
    const issues = check(
      [
        football("2026-11-10"),
        football("2026-11-12"),
        football("2026-11-14"),
        ev({ id: "call", date: "2026-11-11", start: "10:00", end: "10:30", title: "Call" }),
      ],
      { away },
    );
    expect(ofKind(issues, "away_clash")).toEqual([
      expect.objectContaining({
        key: "away_clash:foot@2026-11-10,foot@2026-11-12",
        date: "2026-11-10",
        severity: "warning",
        people: [{ id: "max", name: "Max" }],
        data: { away: "Vacation", dates: ["2026-11-10", "2026-11-12"] },
      }),
      expect.objectContaining({ key: "away_clash:call", people: [], data: { away: "Vacation", dates: ["2026-11-11"] } }),
    ]);
  });

  it("isn't an event far away, at an unknown place, all day or outside the away days", () => {
    const issues = check(
      [
        ev({ date: "2026-11-10", start: "10:00", location: "Munich" }),
        ev({ date: "2026-11-10", start: "12:00", location: "Somewhere unknown" }),
        ev({ date: "2026-11-11" }),
        ev({ date: "2026-11-13", start: "10:00" }),
      ],
      { away },
    );
    expect(ofKind(issues, "away_clash")).toEqual([]);
  });
});

describe("drivers_needed", () => {
  const football = ev({ id: "f", date: "2026-11-05", start: "16:00", end: "17:00", location: "Pool", person: "Max" });
  const ballet = ev({ id: "b", date: "2026-11-05", start: "16:30", end: "17:30", location: "School", person: "Mia" });

  it("is children at different places at once with fewer adults free than places", () => {
    const work = ev({ id: "w", date: "2026-11-05", start: "15:00", end: "18:00", person: "Anna" });
    const issues = check([football, ballet, work]);
    expect(ofKind(issues, "drivers_needed")).toEqual([
      expect.objectContaining({
        key: "drivers_needed:b,f",
        date: "2026-11-05",
        severity: "warning",
        people: [
          { id: "max", name: "Max" },
          { id: "mia", name: "Mia" },
        ],
        data: { children: 2, adults: 1 },
      }),
    ]);
    // An adult going along covers that place: Max still needs someone, and nobody is free.
    const withBen = { ...ballet, person: "Mia & Ben" };
    expect(ofKind(check([football, withBen, work]), "drivers_needed")[0].data).toEqual({ children: 1, adults: 0 });
  });

  it("isn't enough adults free, one place, or times apart", () => {
    expect(ofKind(check([football, ballet]), "drivers_needed")).toEqual([]);
    expect(ofKind(check([football, { ...ballet, location: "Pool" }, ev({ date: "2026-11-05", start: "15:00", end: "18:00", person: "Anna & Ben" })]), "drivers_needed")).toEqual([]);
    expect(ofKind(check([football, { ...ballet, start: "17:00", end: "18:00" }, ev({ date: "2026-11-05", start: "15:00", end: "18:00", person: "Anna & Ben" })]), "drivers_needed")).toEqual([]);
    // Anna free, Ben goes with Mia: Anna takes Max.
    const work = ev({ date: "2026-11-05", start: "15:00", end: "18:00", person: "Ben" });
    expect(ofKind(check([football, { ...ballet, person: "Mia & Ben" }, work]), "drivers_needed")).toEqual([]);
  });
});

describe("birthday_away", () => {
  // Mia turns 8 on 2026-11-05.
  it("is someone on a trip or far away on another one's birthday (info)", () => {
    const trip = ev({ id: "trip", date: "2026-11-04", endDate: "2026-11-06", location: "Munich", person: "Ben" });
    const hamburg = ev({ id: "hh", date: "2026-11-05", start: "10:00", end: "12:00", location: "Hamburg", person: "Anna" });
    const issues = ofKind(check([trip, hamburg]), "birthday_away");
    expect(issues).toEqual([
      expect.objectContaining({
        key: "birthday_away:mia:hh",
        date: "2026-11-05",
        severity: "info",
        people: [{ id: "anna", name: "Anna Krug" }],
        data: { name: "Mia", age: 8 },
      }),
      expect.objectContaining({ key: "birthday_away:mia:trip", people: [{ id: "ben", name: "Ben" }] }),
    ]);
  });

  it("isn't a trip together, an event near home or a day the family is away", () => {
    const together = ev({ date: "2026-11-04", endDate: "2026-11-06", location: "Munich", person: "Ben & Mia" });
    const near = ev({ date: "2026-11-05", start: "10:00", location: "Potsdam", person: "Anna" });
    expect(ofKind(check([together, near]), "birthday_away")).toEqual([]);
    const trip = ev({ date: "2026-11-04", endDate: "2026-11-06", location: "Munich", person: "Ben" });
    expect(ofKind(check([trip], { away: new Map([["2026-11-05", ["Vacation"]]]) }), "birthday_away")).toEqual([]);
  });
});

describe("issues", () => {
  it("come sorted by date, then severity", () => {
    const issues = check([
      // 2026-11-04: an unassigned overlap (info) and an overlap (conflict)
      ev({ date: "2026-11-04", start: "18:00", end: "19:00" }),
      ev({ date: "2026-11-04", start: "18:30", end: "19:00" }),
      ev({ date: "2026-11-04", start: "09:00", end: "10:00", person: "Ben" }),
      ev({ date: "2026-11-04", start: "09:30", end: "10:30", person: "Ben" }),
      // 2026-11-03: a packed day (warning)
      ev({ date: "2026-11-03", start: "08:00", end: "17:00", person: "Max" }),
    ]);
    expect(issues.map((i) => [i.date, i.severity])).toEqual([
      ["2026-11-03", "warning"],
      ["2026-11-04", "conflict"],
      ["2026-11-04", "info"],
    ]);
  });

  it("have deterministic keys, hashed when long", () => {
    expect(issueKey("overlap", ["b", "a"])).toBe("overlap:a,b");
    expect(issueKey("birthday_away", ["x"], "mia")).toBe("birthday_away:mia:x");
    const long = issueKey("away_clash", Array.from({ length: 20 }, (_, i) => `series-${i}@2026-11-${String(i + 1).padStart(2, "0")}`));
    expect(long).toMatch(/^away_clash:#[0-9a-f]{32}$/);
    expect(issueKey("away_clash", Array.from({ length: 20 }, (_, i) => `series-${i}@2026-11-${String(i + 1).padStart(2, "0")}`))).toBe(long);
  });

  it("are none for an empty calendar", () => {
    expect(check([])).toEqual([]);
  });
});
