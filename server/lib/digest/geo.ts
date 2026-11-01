// The week ahead (phase 11): where events are. The worker geocodes the locations of the next
// 14 days' events once a day with Photon (photon.komoot.io, biased to the family's home), at
// most GEO_MAX_PER_DAY look-ups per family and day, into `geo_places`; requests only read
// that cache. A miss is tried again after MISS_RETRY_DAYS, a hit refreshed after
// HIT_REFRESH_DAYS. DIGEST_GEOCODE=0 turns it off (no look-ups, the cache isn't used): the
// travel checks then only compare the locations' text.

import { and, eq, gte, inArray, sql } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { families, geoPlaces } from "@/lib/db/schema";
import { addDays } from "@/lib/calendar/dates";
import { listOccurrences } from "@/lib/calendar/events";
import { timeoutSignal } from "@/lib/appointments/http";
import { type Coord, placeKey } from "./travel";

export const DIGEST_DAYS = 14;
export const GEO_MAX_PER_DAY = 25;
export const MISS_RETRY_DAYS = 7;
export const HIT_REFRESH_DAYS = 180;
const LOOKUP_TIMEOUT_MS = 10_000;
const DAY_MS = 86_400_000;
const PHOTON_URL = "https://photon.komoot.io/api/";

/** Finds a place: its coordinates, null when there are none; throws when it can't tell (the
 *  geocoder can't be reached), so nothing is cached. */
export type PlaceLookup = (query: string, bias: Coord | null) => Promise<Coord | null>;

/** Whether locations are geocoded (DIGEST_GEOCODE=0: no). */
export function geocodingEnabled(env: Record<string, string | undefined> = process.env): boolean {
  return env.DIGEST_GEOCODE !== "0";
}

/** Photon's top hit, near `bias` when given. */
export const photonLookup: PlaceLookup = async (query, bias) => {
  const params = new URLSearchParams({ q: query, limit: "1" });
  if (bias) {
    params.set("lat", String(bias.lat));
    params.set("lon", String(bias.lng));
  }
  const res = await fetch(`${PHOTON_URL}?${params}`, {
    headers: { Accept: "application/json" },
    signal: timeoutSignal(LOOKUP_TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`Photon answered ${res.status}`);
  const body = (await res.json()) as { features?: { geometry?: { coordinates?: unknown[] } }[] };
  const coords = body.features?.[0]?.geometry?.coordinates;
  if (!Array.isArray(coords) || coords.length < 2) return null;
  const [lng, lat] = coords.map(Number);
  return Number.isFinite(lat) && Number.isFinite(lng) ? { lat, lng } : null;
};

/** The family's home coordinates, or null. */
export function homeOf(db: Db, familyId: string): Coord | null {
  const f = db.select({ lat: families.homeLat, lng: families.homeLng }).from(families).where(eq(families.id, familyId)).get();
  return f && f.lat !== null && f.lng !== null ? { lat: f.lat, lng: f.lng } : null;
}

/** placeKey → coordinates of the given locations found in the cache (misses left out). */
export function cachedPlaces(db: Db, familyId: string, locations: Iterable<string>): Map<string, Coord> {
  const keys = [...new Set([...locations].map(placeKey).filter(Boolean))];
  const out = new Map<string, Coord>();
  for (let i = 0; i < keys.length; i += 500) {
    const rows = db
      .select()
      .from(geoPlaces)
      .where(and(eq(geoPlaces.familyId, familyId), inArray(geoPlaces.query, keys.slice(i, i + 500))))
      .all();
    for (const r of rows) if (r.lat !== null && r.lng !== null) out.set(r.query, { lat: r.lat, lng: r.lng });
  }
  return out;
}

export interface RefreshResult {
  /** Look-ups made (found or not). */
  looked: number;
  found: number;
  /** Look-ups that failed (the rest of the round is skipped). */
  failed: number;
}

/** Geocodes the locations of the family's events from `today` on (DIGEST_DAYS days) that aren't
 *  cached or are due again, at most `max` per family in 24 hours. Never throws. */
export async function refreshPlaces(
  db: Db,
  familyId: string,
  today: string,
  opts: { lookup?: PlaceLookup; max?: number; now?: Date; enabled?: boolean } = {},
): Promise<RefreshResult> {
  const result: RefreshResult = { looked: 0, found: 0, failed: 0 };
  if (!(opts.enabled ?? geocodingEnabled())) return result;
  try {
    const now = opts.now ?? new Date();
    const lookup = opts.lookup ?? photonLookup;
    const max = opts.max ?? GEO_MAX_PER_DAY;
    const texts = new Map<string, string>();
    for (const e of listOccurrences(db, familyId, { from: today, to: addDays(today, DIGEST_DAYS - 1) })) {
      const key = placeKey(e.location);
      if (key && key.length <= 300 && !texts.has(key)) texts.set(key, e.location.trim());
    }
    if (texts.size === 0) return result;
    const rows = new Map(
      db
        .select()
        .from(geoPlaces)
        .where(eq(geoPlaces.familyId, familyId))
        .all()
        .map((r) => [r.query, r]),
    );
    const since = (days: number) => now.getTime() - days * DAY_MS;
    // Never looked up first, then misses to retry, then hits to refresh.
    const due = [...texts.keys()]
      .map((key) => {
        const r = rows.get(key);
        if (!r) return { key, rank: 0 };
        if (r.lat === null && r.lookedUpAt.getTime() <= since(MISS_RETRY_DAYS)) return { key, rank: 1 };
        if (r.lat !== null && r.lookedUpAt.getTime() <= since(HIT_REFRESH_DAYS)) return { key, rank: 2 };
        return null;
      })
      .filter((d): d is { key: string; rank: number } => d !== null)
      .sort((a, b) => a.rank - b.rank || a.key.localeCompare(b.key));
    const usedToday =
      db
        .select({ n: sql<number>`count(*)` })
        .from(geoPlaces)
        .where(and(eq(geoPlaces.familyId, familyId), gte(geoPlaces.lookedUpAt, new Date(since(1)))))
        .get()?.n ?? 0;
    const budget = Math.max(0, max - usedToday);
    const bias = homeOf(db, familyId);
    for (const { key } of due.slice(0, budget)) {
      let found: Coord | null;
      try {
        found = await lookup(texts.get(key)!, bias);
      } catch (e) {
        result.failed += 1;
        console.warn(`[digest] geocoding failed for family ${familyId}:`, e instanceof Error ? e.message : e);
        break; // the geocoder is down: try again tomorrow
      }
      result.looked += 1;
      if (found) result.found += 1;
      // A hit that isn't found again keeps its coordinates.
      const old = rows.get(key);
      const at = found ?? (old && old.lat !== null && old.lng !== null ? { lat: old.lat, lng: old.lng } : null);
      const values = { lat: at?.lat ?? null, lng: at?.lng ?? null, lookedUpAt: now };
      db.insert(geoPlaces)
        .values({ familyId, query: key, ...values })
        .onConflictDoUpdate({ target: [geoPlaces.familyId, geoPlaces.query], set: values })
        .run();
    }
  } catch (e) {
    console.error(`[digest] refreshing places of family ${familyId} failed:`, e);
  }
  return result;
}
