// The holidays' region from the family's home: Photon's reverse look-up of the home coordinates
// gives the country and the state ("DE", "Bayern"), which is matched by name against
// OpenHolidays' subdivisions (any language, case and accents ignored), then the city, county or
// district against their children (a municipality with holidays of its own). A state that isn't
// found leaves the country (its nationwide days); a country OpenHolidays doesn't know is
// unsupported.

import { timeoutSignal } from "@/lib/appointments/http";
import type { Coord } from "@/lib/digest/travel";
import { normalizeForSearch } from "@/lib/meals/domain/recipes/search";
import type { Country, HolidaySource, Subdivision } from "./openholidays";

const PHOTON_REVERSE_URL = "https://photon.komoot.io/reverse";
const LOOKUP_TIMEOUT_MS = 10_000;

/** Where coordinates are: the country's ISO code and the names around it (local language). */
export interface Place {
  country: string;
  state: string | null;
  county: string | null;
  city: string | null;
  district: string | null;
}

/** Finds the place at `coord`: null when there is none (the sea); throws when it can't tell. */
export type ReverseLookup = (coord: Coord) => Promise<Place | null>;

const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : null);

/** Photon's place at `coord`. */
export const photonReverse: ReverseLookup = async ({ lat, lng }) => {
  const params = new URLSearchParams({ lat: String(lat), lon: String(lng), limit: "1" });
  const res = await fetch(`${PHOTON_REVERSE_URL}?${params}`, {
    headers: { Accept: "application/json" },
    signal: timeoutSignal(LOOKUP_TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`Photon answered ${res.status}`);
  return parsePhotonPlace(await res.json());
};

/** The place of Photon's first feature, or null. */
export function parsePhotonPlace(body: unknown): Place | null {
  const p = (body as { features?: { properties?: Record<string, unknown> }[] })?.features?.[0]?.properties;
  const country = str(p?.countrycode)?.toUpperCase();
  if (!p || !country || !/^[A-Z]{2}$/.test(country)) return null;
  return { country, state: str(p.state), county: str(p.county), city: str(p.city), district: str(p.district) };
}

/** The key of home coordinates a region was detected for ("lat,lng"). */
export function regionKey(c: Coord): string {
  return `${c.lat},${c.lng}`;
}

const fold = (s: string) =>
  normalizeForSearch(s)
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();

const named = (s: Subdivision, names: (string | null)[]) => {
  const wanted = new Set(names.filter((n): n is string => !!n).map(fold));
  return Object.values(s.names).some((n) => wanted.has(fold(n)));
};

/** The region code of `place`: its state's subdivision (and, below it, the one of its city,
 *  county or district), else just the country; null when OpenHolidays doesn't know the country. */
export function matchRegion(place: Place, countries: Country[], subdivisions: Subdivision[]): string | null {
  if (!countries.some((c) => c.code === place.country)) return null;
  const top = (names: (string | null)[]) => subdivisions.find((s) => s.code.startsWith(`${place.country}-`) && named(s, names));
  // City-states (Berlin, Hamburg, Wien) come without a state: the city is the state.
  let found = top([place.state]) ?? top([place.city]);
  if (!found) return place.country;
  const local = [place.city, place.county, place.district];
  for (let child = found.children.find((s) => named(s, local)); child; child = child.children.find((s) => named(s, local))) {
    found = child;
  }
  return found.code;
}

/** The region at `coord`, or null when it's unsupported. Throws when a service can't be reached. */
export async function detectRegion(source: HolidaySource, reverse: ReverseLookup, coord: Coord): Promise<string | null> {
  const place = await reverse(coord);
  if (!place) return null;
  const countries = await source.countries();
  if (!countries.some((c) => c.code === place.country)) return null;
  return matchRegion(place, countries, await source.subdivisions(place.country));
}

/** The path from the country to the subdivision `code` (both included), or null. */
function pathTo(list: Subdivision[], code: string): Subdivision[] | null {
  for (const s of list) {
    if (s.code === code) return [s];
    if (code.startsWith(`${s.code}-`)) {
      const below = pathTo(s.children, code);
      if (below) return [s, ...below];
    }
  }
  return null;
}

/** The region's name by language, most specific first: {de: "Bayern, Deutschland", en:
 *  "Bavaria, Germany"}; a code that isn't found is named by what is (at least the country's
 *  name). Empty when the country is unknown. */
export function regionNames(code: string, countries: Country[], subdivisions: Subdivision[]): Record<string, string> {
  const country = countries.find((c) => c.code === code.slice(0, 2));
  if (!country) return {};
  const parts = [...(pathTo(subdivisions, code) ?? [])].reverse().map((s) => s.names);
  parts.push(country.names);
  const langs = new Set(parts.flatMap((p) => Object.keys(p)));
  const out: Record<string, string> = {};
  for (const lang of langs) {
    out[lang] = parts
      .map((p) => p[lang] ?? p.en ?? Object.values(p)[0])
      .filter(Boolean)
      .join(", ");
  }
  return out;
}

/** regionNames from the source (its lists are kept for a day). */
export async function lookUpRegionNames(source: HolidaySource, code: string): Promise<Record<string, string>> {
  const countries = await source.countries();
  if (!countries.some((c) => c.code === code.slice(0, 2))) return {};
  return regionNames(code, countries, code.length > 2 ? await source.subdivisions(code.slice(0, 2)) : []);
}
