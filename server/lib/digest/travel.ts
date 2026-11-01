// The week ahead (phase 11): how long it takes to get from one place to another. An estimate,
// not a route: the straight line × 1.3 (roads aren't straight), at 30 km/h under 20 km (town),
// 60 km/h under 80 km (country roads), 90 km/h beyond (motorway), plus 10 minutes (parking,
// getting in and out). The speed bands go by that road distance. Pure.

import { haversineKm } from "@/lib/appointments/distance";

export interface Coord {
  lat: number;
  lng: number;
}

/** Road distance per straight-line km. */
export const ROAD_FACTOR = 1.3;
/** Minutes on top of every trip. */
export const TRAVEL_OVERHEAD_MINUTES = 10;
/** km/h by road distance: under 20 km, under 80 km, beyond. */
export const SPEED_BANDS = [
  { below: 20, kmh: 30 },
  { below: 80, kmh: 60 },
  { below: Infinity, kmh: 90 },
] as const;

/** The straight-line distance in km. */
export function distanceKm(a: Coord, b: Coord): number {
  return haversineKm(a.lat, a.lng, b.lat, b.lng);
}

/** The estimated road distance in km for a straight-line distance. */
export function roadKm(straightKm: number): number {
  return straightKm * ROAD_FACTOR;
}

/** Estimated minutes on the road for a straight-line distance (unrounded). */
export function travelMinutesFor(straightKm: number): number {
  const road = roadKm(straightKm);
  const kmh = SPEED_BANDS.find((b) => road < b.below)!.kmh;
  return (road / kmh) * 60 + TRAVEL_OVERHEAD_MINUTES;
}

/** The estimate between two places: straight-line km, road km and minutes (unrounded). */
export function estimateTravel(a: Coord, b: Coord): { km: number; roadKm: number; minutes: number } {
  const km = distanceKm(a, b);
  return { km, roadKm: roadKm(km), minutes: travelMinutesFor(km) };
}

/** km as the digest shows them: whole km, one decimal under 10. */
export function roundKm(km: number): number {
  return km < 10 ? Math.round(km * 10) / 10 : Math.round(km);
}

/** A location as the cache keys it: trimmed, spaces collapsed, lower case (accents kept: they
 *  tell places apart). "" for none. */
export function placeKey(location: string): string {
  return location.normalize("NFC").trim().replace(/\s+/g, " ").toLowerCase();
}
