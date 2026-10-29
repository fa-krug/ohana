import type { SourceId } from "./types";

/** Canonical ignore key. Used at collection AND display time — never inline this string. */
export function ignoreKey(source: SourceId, slug: string, motiveId: number | null): string {
  return `${source}␟${slug}␟${motiveId}`;
}

/**
 * Cross-source dedup identity: normalized doctor name + a locality token.
 *
 * Coordinates are the only locality signal both sources share (jameda listings expose
 * lat/lng but no zipcode), so they take priority — rounded to 2 decimals (~1.1 km) to
 * absorb the small differences between Doctolib's and jameda's geocoders while an exact
 * name match keeps distinct doctors apart. Falls back to zipcode when coords are absent,
 * and returns "" when neither is available so the caller can keep the row unique.
 */
export function dedupKey(
  doctorName: string,
  latitude: string,
  longitude: string,
  zipcode: string,
): string {
  const name = doctorName.trim().toLowerCase();
  const lat = Number.parseFloat(latitude);
  const lng = Number.parseFloat(longitude);
  if (!Number.isNaN(lat) && !Number.isNaN(lng)) {
    return `${name}␟${lat.toFixed(2)}␟${lng.toFixed(2)}`;
  }
  const zip = zipcode.trim().toLowerCase();
  if (zip) return `${name}␟${zip}`;
  return "";
}
