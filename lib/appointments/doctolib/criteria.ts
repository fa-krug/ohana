import type { Criteria } from "./client";

export interface SearchTarget {
  specialitySlug: string;
  latitude: string;
  longitude: string;
  insuranceSector: string;
}

/** Assemble the Doctolib search URL on demand (mirrors Search.build_doctolib_url). */
export function buildDoctolibUrl(s: SearchTarget): string {
  const params = new URLSearchParams({
    around_me: "true",
    keyword: s.specialitySlug,
    latitude: s.latitude,
    longitude: s.longitude,
  });
  if (s.insuranceSector) params.set("insuranceSector", s.insuranceSector);
  return `https://www.doctolib.de/search?${params}`;
}

/** {keyword, lat, lng, filters} for the pipeline; throws when GPS is missing. */
export function searchCriteria(s: SearchTarget): Criteria {
  if (!s.latitude || !s.longitude) {
    throw new Error("search is missing latitude/longitude");
  }
  const filters = s.insuranceSector ? { insuranceSector: s.insuranceSector } : {};
  return { keyword: s.specialitySlug || "", lat: s.latitude, lng: s.longitude, filters };
}
