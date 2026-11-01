// The week ahead (phase 11): the checks. Rules, not the model: pure functions over the
// occurrences of a range (normally the next 14 days), the family's people, its away days, its
// home and the event locations geocoded so far. Deterministic: the same input gives the same
// issues with the same keys, so an issue dismissed once stays dismissed.
//
// Terms used below:
// - a *timed* event has a start and lasts at most a day (no end: DEFAULT_DURATION_MINUTES);
//   its day is the day it starts. Only timed events can clash.
// - a *trip* is an event over several days with a location (all day or timed).
// - a person's events: those whose `person` names them (./attribution.ts); events naming
//   nobody are the family's ("unassigned").
// - places: two locations are the same when their text is (case and spaces ignored) or, both
//   geocoded, they are less than SAME_PLACE_KM apart; an empty location is unknown.
//
// Distances from home (travel_week, away_clash, birthday_away) are straight lines; `km` in an
// issue's data is the estimated road distance (./travel.ts), like its minutes.

import { createHash } from "node:crypto";
import { addDays, diffDays, weekday } from "@/lib/calendar/dates";
import type { PublicEvent } from "@/lib/calendar/events";
import { birthdaysIn } from "@/lib/families/birthdays";
import { type FamilyPerson, attributor, isAdult, isChild } from "./attribution";
import { type Coord, distanceKm, placeKey, roadKm, roundKm, travelMinutesFor } from "./travel";

export const ISSUE_KINDS = [
  "overlap",
  "tight_transfer",
  "during_trip",
  "packed_day",
  "long_travel_day",
  "travel_week",
  "short_night",
  "away_clash",
  "drivers_needed",
  "birthday_away",
  "unassigned_overlap",
] as const;
export type IssueKind = (typeof ISSUE_KINDS)[number];

export const SEVERITIES = ["conflict", "warning", "info"] as const;
export type Severity = (typeof SEVERITIES)[number];

// ---- thresholds ----

/** A timed event without an end lasts this long. */
export const DEFAULT_DURATION_MINUTES = 60;
/** Geocoded places closer than this are the same place. */
export const SAME_PLACE_KM = 0.3;
/** tight_transfer without coordinates: a gap under this between different places. */
export const TRANSFER_TEXT_GAP_MINUTES = 15;
/** during_trip: an event further than this from the trip's place is elsewhere. */
export const ELSEWHERE_KM = 30;
/** packed_day: this many timed events, or this many hours booked. */
export const PACKED_DAY_EVENTS = 4;
export const PACKED_DAY_HOURS = 9;
/** long_travel_day: home → events → home this many minutes or road km. */
export const LONG_TRAVEL_MINUTES = 150;
export const LONG_TRAVEL_KM = 200;
/** travel_week and birthday_away: this far from home is far away. */
export const FAR_FROM_HOME_KM = 50;
/** travel_week: this many days far from home in one week (Mon–Sun). */
export const TRAVEL_WEEK_DAYS = 3;
/** short_night: less than this many hours between getting home and leaving again. */
export const SHORT_NIGHT_HOURS = 9;
/** away_clash: an event within this distance of home is at home. */
export const NEAR_HOME_KM = 30;
/** Keys longer than this are hashed (they end up in a URL). */
const MAX_KEY_LENGTH = 200;

const DAY_MINUTES = 1440;

// ---- shapes ----

/** What the checks read of an occurrence. */
export type CheckEvent = Pick<
  PublicEvent,
  "id" | "occurrence" | "date" | "endDate" | "start" | "end" | "title" | "location" | "person"
>;

export interface IssueEvent {
  id: string;
  occurrence: string | null;
  title: string;
  date: string;
  endDate: string;
  start: string | null;
  end: string | null;
  location: string;
}

export interface IssuePerson {
  id: string | null;
  name: string;
}

export interface Issue {
  key: string;
  kind: IssueKind;
  severity: Severity;
  date: string;
  /** Who it is about ([] for unassigned events). */
  people: IssuePerson[];
  events: IssueEvent[];
  data: Record<string, unknown>;
  dismissed: boolean;
}

export interface CheckInput {
  /** The range, inclusive. */
  from: string;
  to: string;
  /** The occurrences overlapping the range. */
  events: CheckEvent[];
  /** familyNames: everyone in the family. */
  people: FamilyPerson[];
  /** Days the family is away ("away" types) → the types' names. */
  away: Map<string, string[]>;
  home: Coord | null;
  /** placeKey(location) → coordinates, for the locations geocoded so far. */
  places: Map<string, Coord>;
}

export const SEVERITY_RANK: Record<Severity, number> = { conflict: 0, warning: 1, info: 2 };

/** Sorts issues by date, then severity (conflict, warning, info), then kind and key. */
export function sortIssues(issues: Issue[]): Issue[] {
  return issues.sort(
    (a, b) =>
      a.date.localeCompare(b.date) ||
      SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity] ||
      ISSUE_KINDS.indexOf(a.kind) - ISSUE_KINDS.indexOf(b.kind) ||
      a.key.localeCompare(b.key),
  );
}

// ---- helpers ----

interface Ev {
  e: CheckEvent;
  ref: string;
  people: string[];
  /** Absolute minutes since `from` 00:00. */
  startMin: number;
  endMin: number;
  timed: boolean;
  trip: boolean;
  /** placeKey of the location ("" for none). */
  loc: string;
  coord: Coord | null;
}

const round1 = (n: number) => Math.round(n * 10) / 10;
const hm = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
export const refOf = (e: { id: string; occurrence: string | null }) => (e.occurrence ? `${e.id}@${e.occurrence}` : e.id);

/** The key of an issue: its kind, an extra part (a person) and the sorted refs of its events. */
export function issueKey(kind: IssueKind, refs: string[], extra?: string): string {
  const key = `${kind}:${extra ? `${extra}:` : ""}${[...refs].sort().join(",")}`;
  return key.length <= MAX_KEY_LENGTH ? key : `${kind}:#${createHash("sha256").update(key).digest("hex").slice(0, 32)}`;
}

const issueEvent = (e: CheckEvent): IssueEvent => ({
  id: e.id,
  occurrence: e.occurrence,
  title: e.title,
  date: e.date,
  endDate: e.endDate,
  start: e.start,
  end: e.end,
  location: e.location,
});

/** Whether two events are at the same place: true, false, or null when one has no location. */
function samePlace(a: Ev, b: Ev): boolean | null {
  if (!a.loc || !b.loc) return null;
  if (a.loc === b.loc) return true;
  if (a.coord && b.coord) return distanceKm(a.coord, b.coord) < SAME_PLACE_KM;
  return false;
}

/** The checks over the range. Issues come sorted; `dismissed` is false (the caller marks them). */
export function checkSchedule(input: CheckInput): Issue[] {
  const { from, to, people, away, home, places } = input;
  const attribute = attributor(people);
  const byId = new Map(people.map((p) => [p.id, p]));
  const abs = (date: string, time: string) => diffDays(from, date) * DAY_MINUTES + hm(time);
  const dayAt = (min: number) => addDays(from, Math.floor(min / DAY_MINUTES));
  const dayStart = (day: string) => diffDays(from, day) * DAY_MINUTES;

  // The occurrences, enriched.
  const evs: Ev[] = input.events.map((e) => {
    const startMin = e.start ? abs(e.date, e.start) : dayStart(e.date);
    let endMin: number;
    if (e.start && e.end) endMin = abs(e.endDate, e.end);
    else if (e.start && e.date === e.endDate) endMin = startMin + DEFAULT_DURATION_MINUTES;
    else endMin = dayStart(e.endDate) + DAY_MINUTES;
    const loc = placeKey(e.location);
    const timed = !!e.start && endMin - startMin <= DAY_MINUTES;
    return {
      e,
      ref: refOf(e),
      people: attribute(e.person),
      startMin,
      endMin,
      timed,
      trip: !timed && e.date < e.endDate && !!loc,
      loc,
      coord: (loc && places.get(loc)) || null,
    };
  });
  const inRange = (day: string) => day >= from && day <= to;
  const timed = evs.filter((v) => v.timed && inRange(v.e.date)).sort((a, b) => a.startMin - b.startMin || a.endMin - b.endMin);
  const trips = evs.filter((v) => v.trip);
  /** Single-day events (timed or all day) that aren't trips: where someone is on a day. */
  const dayEvents = evs.filter((v) => !v.trip && (v.timed || v.e.date === v.e.endDate) && inRange(v.e.date));

  const ofPerson = (list: Ev[], id: string) => list.filter((v) => v.people.includes(id));
  const tripDays = (id: string): Set<string> => {
    const out = new Set<string>();
    for (const t of ofPerson(trips, id)) {
      for (let d = t.e.date > from ? t.e.date : from; d <= t.e.endDate && d <= to; d = addDays(d, 1)) out.add(d);
    }
    return out;
  };
  const fromHome = (v: Ev) => (home && v.coord ? distanceKm(home, v.coord) : null);

  // Issues with the same key are one issue (e.g. two people with the same two clashing events).
  const issues = new Map<string, Issue>();
  const add = (
    kind: IssueKind,
    severity: Severity,
    date: string,
    personIds: string[],
    events: Ev[],
    data: Record<string, unknown>,
    extra?: string,
  ) => {
    const key = issueKey(
      kind,
      events.map((v) => v.ref),
      extra,
    );
    const existing = issues.get(key);
    if (existing) {
      for (const id of personIds) {
        if (!existing.people.some((p) => p.id === id)) existing.people.push({ id, name: byId.get(id)?.name ?? "" });
      }
      return;
    }
    issues.set(key, {
      key,
      kind,
      severity,
      date,
      people: personIds.map((id) => ({ id, name: byId.get(id)?.name ?? "" })),
      events: events.map((v) => issueEvent(v.e)),
      data,
      dismissed: false,
    });
  };

  /** Pairs of overlapping events of a list sorted by start, with the minutes they overlap. */
  const overlaps = (list: Ev[]): [Ev, Ev, number][] => {
    const out: [Ev, Ev, number][] = [];
    for (let i = 0; i < list.length; i++) {
      for (let j = i + 1; j < list.length && list[j].startMin < list[i].endMin; j++) {
        const minutes = Math.min(list[i].endMin, list[j].endMin) - list[j].startMin;
        if (minutes > 0) out.push([list[i], list[j], minutes]);
      }
    }
    return out;
  };

  for (const p of people) {
    const mine = ofPerson(timed, p.id);
    const myTrips = ofPerson(trips, p.id);
    const onTrip = tripDays(p.id);

    // overlap: two timed events at the same time.
    for (const [a, b, minutes] of overlaps(mine)) add("overlap", "conflict", dayAt(b.startMin), [p.id], [a, b], { minutes });

    // tight_transfer: the next event elsewhere starts before one can get there.
    for (let i = 0; i + 1 < mine.length; i++) {
      const a = mine[i];
      const b = mine[i + 1];
      const gap = b.startMin - a.endMin;
      if (gap < 0 || samePlace(a, b) !== false) continue;
      if (a.coord && b.coord) {
        const km = distanceKm(a.coord, b.coord);
        const travel = travelMinutesFor(km);
        if (gap < travel) {
          add("tight_transfer", "conflict", dayAt(b.startMin), [p.id], [a, b], {
            gapMinutes: Math.round(gap),
            travelMinutes: Math.round(travel),
            km: roundKm(roadKm(km)),
          });
        }
      } else if (gap < TRANSFER_TEXT_GAP_MINUTES) {
        add("tight_transfer", "warning", dayAt(b.startMin), [p.id], [a, b], { gapMinutes: Math.round(gap), travelMinutes: null, km: null });
      }
    }

    // during_trip: a timed event elsewhere while on a trip.
    for (const t of myTrips) {
      for (const v of mine) {
        if (v.e.id === t.e.id || v.startMin >= t.endMin || v.endMin <= t.startMin || !v.loc) continue;
        const elsewhere =
          t.coord && v.coord ? distanceKm(t.coord, v.coord) > ELSEWHERE_KM : !(t.loc.includes(v.loc) || v.loc.includes(t.loc));
        if (elsewhere) add("during_trip", "warning", v.e.date, [p.id], [t, v], {});
      }
    }

    // packed_day, long_travel_day, short_night: by day.
    const byDay = new Map<string, Ev[]>();
    for (const v of mine) byDay.set(dayAt(v.startMin), [...(byDay.get(dayAt(v.startMin)) ?? []), v]);
    for (const [day, list] of byDay) {
      // Hours booked: the union of the events' times on that day.
      const start = dayStart(day);
      let booked = 0;
      let until = start;
      for (const v of list) {
        const s = Math.max(v.startMin, until);
        const e = Math.min(v.endMin, start + DAY_MINUTES);
        if (e > s) booked += e - s;
        until = Math.max(until, Math.min(v.endMin, start + DAY_MINUTES));
      }
      if (list.length >= PACKED_DAY_EVENTS || booked >= PACKED_DAY_HOURS * 60) {
        add("packed_day", "warning", day, [p.id], list, { events: list.length, hours: round1(booked / 60) });
      }
    }

    if (home) {
      // long_travel_day: home → the day's events → home (not on trips or away days).
      const days = new Map<string, Ev[]>();
      for (const v of ofPerson(dayEvents, p.id)) {
        if (!v.coord) continue;
        const day = v.timed ? dayAt(v.startMin) : v.e.date;
        if (onTrip.has(day) || away.has(day) || !inRange(day)) continue;
        days.set(day, [...(days.get(day) ?? []), v]);
      }
      for (const [day, list] of days) {
        // All-day ones first (their time isn't known), then by start.
        const route = [...list].sort((a, b) => Number(a.timed) - Number(b.timed) || a.startMin - b.startMin);
        let km = 0;
        let minutes = 0;
        let at: Coord = home;
        for (const c of [...route.map((v) => v.coord!), home]) {
          const leg = distanceKm(at, c);
          if (leg >= SAME_PLACE_KM) {
            km += roadKm(leg);
            minutes += travelMinutesFor(leg);
          }
          at = c;
        }
        if (minutes >= LONG_TRAVEL_MINUTES || km >= LONG_TRAVEL_KM) {
          add("long_travel_day", "warning", day, [p.id], route, { km: roundKm(km), minutes: Math.round(minutes) });
        }
      }

      // travel_week: 3 or more days of a week (Mon–Sun) with an event far from home.
      const weeks = new Map<string, Map<string, Ev[]>>();
      for (const v of ofPerson(dayEvents, p.id)) {
        const day = v.timed ? dayAt(v.startMin) : v.e.date;
        const km = fromHome(v);
        if (km === null || km < FAR_FROM_HOME_KM || onTrip.has(day) || away.has(day) || !inRange(day)) continue;
        const week = addDays(day, -((weekday(day) + 6) % 7));
        const w = weeks.get(week) ?? new Map<string, Ev[]>();
        w.set(day, [...(w.get(day) ?? []), v]);
        weeks.set(week, w);
      }
      for (const [weekStart, w] of weeks) {
        if (w.size < TRAVEL_WEEK_DAYS) continue;
        const farDays = [...w.keys()].sort();
        add("travel_week", "warning", farDays[0], [p.id], farDays.flatMap((d) => w.get(d)!), { days: w.size, weekStart });
      }
    }

    // short_night: getting home from the last event of a day, leaving for the first of the next.
    for (const [day, list] of byDay) {
      const next = byDay.get(addDays(day, 1));
      if (!next) continue;
      const last = list.reduce((a, b) => (b.endMin > a.endMin ? b : a));
      const first = next[0];
      if (first.startMin < last.endMin) continue; // an overlap, told as such
      const travel = (v: Ev, d: string) => (home && v.coord && !onTrip.has(d) ? travelMinutesFor(distanceKm(home, v.coord)) : 0);
      const night = first.startMin - travel(first, addDays(day, 1)) - (last.endMin + travel(last, day));
      if (night < SHORT_NIGHT_HOURS * 60) {
        add("short_night", "warning", day, [p.id], [last, first], { hours: round1(Math.max(0, night) / 60) });
      }
    }
  }

  // unassigned_overlap: two timed events for nobody in particular at the same time.
  const unassigned = timed.filter((v) => v.people.length === 0);
  for (const [a, b, minutes] of overlaps(unassigned)) add("unassigned_overlap", "info", dayAt(b.startMin), [], [a, b], { minutes });

  // away_clash: while the family is away, a timed event near home or without a location; one
  // issue per series.
  const clashes = new Map<string, Ev[]>();
  for (const v of timed) {
    const day = dayAt(v.startMin);
    if (!away.has(day)) continue;
    const km = fromHome(v);
    if (v.loc ? km === null || km > NEAR_HOME_KM : false) continue;
    clashes.set(v.e.id, [...(clashes.get(v.e.id) ?? []), v]);
  }
  for (const list of clashes.values()) {
    const dates = [...new Set(list.map((v) => dayAt(v.startMin)))].sort();
    const ids = [...new Set(list.flatMap((v) => v.people))];
    add("away_clash", "warning", dates[0], people.filter((p) => ids.includes(p.id)).map((p) => p.id), list, {
      away: away.get(dates[0])!.join(", "),
      dates,
    });
  }

  // drivers_needed: children at different places at the same time, fewer adults free than
  // places without an adult going along.
  for (let day = from; day <= to; day = addDays(day, 1)) {
    const children = new Set(people.filter((p) => isChild(p, day)).map((p) => p.id));
    if (children.size < 2) continue;
    const adults = people.filter((p) => isAdult(p, day)).map((p) => p.id);
    const kids = timed.filter((v) => dayAt(v.startMin) === day && v.loc && v.people.some((id) => children.has(id)));
    // Groups of events connected by overlapping in time.
    const seen = new Set<Ev>();
    for (const v of kids) {
      if (seen.has(v)) continue;
      const group = [v];
      seen.add(v);
      for (let i = 0; i < group.length; i++) {
        for (const w of kids) {
          if (!seen.has(w) && w.startMin < group[i].endMin && group[i].startMin < w.endMin) {
            seen.add(w);
            group.push(w);
          }
        }
      }
      if (group.length < 2) continue;
      // Places: events at the same place share one.
      const placesOf: Ev[][] = [];
      for (const w of group) {
        const at = placesOf.find((pl) => samePlace(pl[0], w) === true);
        if (at) at.push(w);
        else placesOf.push([w]);
      }
      if (placesOf.length < 2) continue;
      const needing = placesOf.filter((pl) => !pl.some((w) => w.people.some((id) => adults.includes(id))));
      const begin = Math.min(...group.map((w) => w.startMin));
      const end = Math.max(...group.map((w) => w.endMin));
      const busy = (id: string) =>
        timed.some((w) => w.people.includes(id) && w.startMin < end && begin < w.endMin) ||
        trips.some((t) => t.people.includes(id) && t.startMin < end && begin < t.endMin);
      const free = adults.filter((id) => !busy(id)).length;
      if (needing.length === 0 || free >= needing.length) continue;
      const kidIds = [...new Set(needing.flat().flatMap((w) => w.people.filter((id) => children.has(id))))];
      const sorted = [...group].sort((a, b) => a.startMin - b.startMin || a.ref.localeCompare(b.ref));
      add(
        "drivers_needed",
        "warning",
        day,
        people.filter((p) => kidIds.includes(p.id)).map((p) => p.id),
        sorted,
        { children: kidIds.length, adults: free },
      );
    }
  }

  // birthday_away: someone on a trip or far from home on another one's birthday.
  for (const p of people) {
    for (const b of birthdaysIn([p], from, to)) {
      if (away.has(b.day)) continue; // the family is away together
      for (const q of people) {
        if (q.id === p.id) continue;
        const coversDay = (v: Ev) => v.e.date <= b.day && v.e.endDate >= b.day && !v.people.includes(p.id);
        const trip = ofPerson(trips, q.id).find((t) => {
          const km = fromHome(t);
          return coversDay(t) && (km === null || km >= FAR_FROM_HOME_KM);
        });
        const far = ofPerson(dayEvents, q.id).find((v) => {
          const km = fromHome(v);
          return coversDay(v) && km !== null && km >= FAR_FROM_HOME_KM;
        });
        const there = trip ?? far;
        if (there) add("birthday_away", "info", b.day, [q.id], [there], { name: p.name, age: b.age }, p.id);
      }
    }
  }

  // People in the family's order.
  const order = new Map(people.map((p, i) => [p.id, i]));
  for (const issue of issues.values()) issue.people.sort((a, b) => order.get(a.id!)! - order.get(b.id!)!);
  return sortIssues([...issues.values()]);
}
