import { dedupKey } from "./keys";
import type { NormalizedResult } from "./types";

export function dedupeResults(results: NormalizedResult[]): NormalizedResult[] {
  const best = new Map<string, NormalizedResult>();
  for (const r of results) {
    // Identity = name + coords (preferred) or zipcode. When neither is available we can't
    // establish cross-source identity, so keep the row unique per source+slug+time.
    const id = dedupKey(r.doctorName, r.practiceLatitude, r.practiceLongitude, r.practiceZipcode);
    const key = id || `${r.source}␟${r.providerSlug}␟${r.slotDatetime.getTime()}`;
    const cur = best.get(key);
    if (!cur) { best.set(key, r); continue; }
    const earlier = r.slotDatetime.getTime() < cur.slotDatetime.getTime();
    const tieBookable = r.slotDatetime.getTime() === cur.slotDatetime.getTime() && !cur.bookingUrl && !!r.bookingUrl;
    if (earlier || tieBookable) best.set(key, r);
  }
  return [...best.values()];
}
