// Pure city-slug helper shared by the jameda source (server) and the search-form
// preview (client). Jameda landing-page paths use this slug: /{speciality}/{citySlug}.

const UMLAUTS: [RegExp, string][] = [
  [/ä/g, "ae"], [/ö/g, "oe"], [/ü/g, "ue"], [/ß/g, "ss"],
];

/** Slugify a location label to jameda's city-path form: "München, Deutschland" → "muenchen". */
export function citySlug(locationLabel: string): string {
  let s = (locationLabel.split(",")[0] ?? "").trim().toLowerCase();
  for (const [re, rep] of UMLAUTS) s = s.replace(re, rep);
  return s.replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}
