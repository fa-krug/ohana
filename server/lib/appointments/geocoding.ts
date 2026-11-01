// Location autocomplete via the Photon geocoder (photon.komoot.io).
//
// The Doctolib scraper searches purely by GPS coordinates, so the location field only
// needs latitude/longitude. Doctolib's own place endpoint is gone, so we geocode with
// Photon — a free, key-less public API. Parsing is pure and unit-tested; the network
// call is a thin wrapper that degrades to "no suggestions" on any error.

import { timeoutSignal } from "./http";

const PHOTON_URL = "https://photon.komoot.io/api/";

export interface LocationSuggestion {
  label: string;
  latitude: string;
  longitude: string;
}

export function parseLocationSuggestions(
  payload: Record<string, unknown>,
): LocationSuggestion[] {
  const out: LocationSuggestion[] = [];
  for (const feat of (payload.features ?? []) as Record<string, unknown>[]) {
    const geometry = (feat.geometry ?? {}) as Record<string, unknown>;
    const coords = (geometry.coordinates ?? []) as number[];
    if (coords.length < 2) continue; // Photon is [lng, lat]; skip malformed features
    const props = (feat.properties ?? {}) as Record<string, unknown>;
    const label = suggestionLabel(props);
    out.push({
      label: label || "(unnamed)",
      latitude: String(coords[1]),
      longitude: String(coords[0]),
    });
  }
  return out;
}

const str = (v: unknown) => (typeof v === "string" ? v.trim() : "");

/** "Name, Street 5, 12345 City": the house number goes with the street (an address picked
 *  from the list keeps it), a name that only repeats the street is left out. */
export function suggestionLabel(props: Record<string, unknown>): string {
  const name = str(props.name);
  const street = [str(props.street), str(props.housenumber)].filter(Boolean).join(" ");
  const place = [str(props.postcode), str(props.city)].filter(Boolean).join(" ");
  const showName = name && ![str(props.street), street, str(props.city)].includes(name);
  return [showName ? name : "", street, place].filter(Boolean).join(", ");
}

export async function suggestLocations(query: string, limit = 5): Promise<LocationSuggestion[]> {
  const params = new URLSearchParams({ q: query, lang: "de", limit: String(limit) });
  try {
    const res = await fetch(`${PHOTON_URL}?${params}`, {
      headers: { Accept: "application/json" },
      signal: timeoutSignal(10_000),
    });
    if (res.status >= 400) return []; // A Photon outage degrades to "no suggestions".
    return parseLocationSuggestions(await res.json());
  } catch {
    return [];
  }
}
