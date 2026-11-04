// Public and school holidays from OpenHolidays (openholidaysapi.org, free, no key): the client
// and the pure parts, i.e. its answers normalized and which holidays apply to a region. Only
// the country and the region go out. HOLIDAYS_URL sets the base (empty: the feature is off).

import { timeoutSignal } from "@/lib/appointments/http";
import { addDays, dateRange } from "../dates";

export const DEFAULT_HOLIDAYS_URL = "https://openholidaysapi.org";

export type HolidayKind = "public" | "school";
export const HOLIDAY_KINDS: readonly HolidayKind[] = ["public", "school"];

/** A full-day holiday as `holiday_cache` keeps it. `names`: by lowercase language ("de",
 *  "en", …); `subdivisions`: the codes it applies to unless `nationwide`. */
export interface CachedHoliday {
  start: string;
  end: string;
  names: Record<string, string>;
  nationwide: boolean;
  subdivisions: string[];
}

export interface Country {
  code: string;
  names: Record<string, string>;
}

/** A region of a country ("DE-BY") with its smaller ones (municipalities, districts). */
export interface Subdivision {
  code: string;
  names: Record<string, string>;
  children: Subdivision[];
}

/** Where the holidays come from (tests: a fake). Throws when it can't be reached. */
export interface HolidaySource {
  countries(): Promise<Country[]>;
  subdivisions(country: string): Promise<Subdivision[]>;
  /** The full-day holidays of `kind` overlapping `year`. */
  holidays(country: string, kind: HolidayKind, year: number): Promise<CachedHoliday[]>;
}

/** The OpenHolidays base URL (HOLIDAYS_URL, default openholidaysapi.org), or null: off. */
export function holidaysUrl(env: Record<string, string | undefined> = process.env): string | null {
  const raw = env.HOLIDAYS_URL ?? DEFAULT_HOLIDAYS_URL;
  return raw.trim().replace(/\/+$/, "") || null;
}

/** OpenHolidays' type of each kind; "Optional", "Bank", "BackToSchool" etc. aren't days off. */
const SOURCE_TYPE: Record<HolidayKind, string> = { public: "Public", school: "School" };
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const CODE_RE = /^[A-Z]{2}(-[A-Z0-9]+)*$/;

/** Whether `v` has the shape of a region code: "DE", "DE-BY", "DE-BY-AU". */
export function isRegionCode(v: unknown): v is string {
  return typeof v === "string" && v.length <= 32 && CODE_RE.test(v);
}

/** [{language: "DE", text: "Bayern"}, …] → {de: "Bayern", …}. */
function namesOf(raw: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (!Array.isArray(raw)) return out;
  for (const n of raw) {
    const lang = typeof n?.language === "string" ? n.language.toLowerCase() : "";
    const text = typeof n?.text === "string" ? n.text.trim() : "";
    if (lang && text && !(lang in out)) out[lang] = text;
  }
  return out;
}

/** The full-day holidays of `kind` in an answer of /PublicHolidays or /SchoolHolidays. */
export function parseHolidays(raw: unknown, kind: HolidayKind): CachedHoliday[] {
  if (!Array.isArray(raw)) throw new Error("OpenHolidays answered something other than a list");
  const out: CachedHoliday[] = [];
  for (const h of raw) {
    if (!h || typeof h !== "object" || h.type !== SOURCE_TYPE[kind] || h.temporalScope !== "FullDay") continue;
    const start = h.startDate;
    const end = h.endDate ?? start;
    if (typeof start !== "string" || typeof end !== "string" || !DATE_RE.test(start) || !DATE_RE.test(end) || end < start) continue;
    const subdivisions = Array.isArray(h.subdivisions)
      ? h.subdivisions.map((s: { code?: unknown }) => s?.code).filter(isRegionCode)
      : [];
    out.push({ start, end, names: namesOf(h.name), nationwide: h.nationwide === true, subdivisions });
  }
  return out;
}

export function parseCountries(raw: unknown): Country[] {
  if (!Array.isArray(raw)) throw new Error("OpenHolidays answered something other than a list");
  return raw
    .filter((c) => isRegionCode(c?.isoCode) && c.isoCode.length === 2)
    .map((c) => ({ code: c.isoCode, names: namesOf(c.name) }));
}

export function parseSubdivisions(raw: unknown): Subdivision[] {
  if (!Array.isArray(raw)) throw new Error("OpenHolidays answered something other than a list");
  return raw
    .filter((s) => isRegionCode(s?.code))
    .map((s) => ({ code: s.code, names: namesOf(s.name), children: Array.isArray(s.children) ? parseSubdivisions(s.children) : [] }));
}

/** Whether `h` applies to `region` ("DE", "DE-BY", "DE-BY-AU") of its country: nationwide, or
 *  one of its subdivisions is the region or contains it. */
export function appliesTo(h: CachedHoliday, region: string, country = region.slice(0, 2)): boolean {
  if (region.slice(0, 2) !== country) return false;
  return h.nationwide || h.subdivisions.some((s) => region === s || region.startsWith(`${s}-`));
}

/** The days from `from` to `to` of the holidays applying to `region`, each with their holidays. */
export function holidayDaysIn(
  list: CachedHoliday[],
  region: string,
  country: string,
  from: string,
  to: string,
): Map<string, CachedHoliday[]> {
  const out = new Map<string, CachedHoliday[]>();
  for (const h of list) {
    if (h.end < from || h.start > to || !appliesTo(h, region, country)) continue;
    const start = h.start < from ? from : h.start;
    const end = h.end > to ? to : h.end;
    for (const day of dateRange(start, end)) {
      const on = out.get(day) ?? [];
      if (!on.some((o) => o.start === h.start && o.end === h.end && sameNames(o, h))) on.push(h);
      out.set(day, on);
    }
  }
  return out;
}

const sameNames = (a: CachedHoliday, b: CachedHoliday) => JSON.stringify(a.names) === JSON.stringify(b.names);

/** A name in `lang`, else English, else the first one. */
export function pickName(names: Record<string, string>, lang: string): string {
  return names[lang] ?? names.en ?? Object.values(names)[0] ?? "";
}

const REQUEST_TIMEOUT_MS = 15_000;
const LISTS_TTL_MS = 86_400_000;

/** The OpenHolidays client at `base`. Countries and subdivisions are kept in memory for a day. */
export function openHolidaysSource(
  base: string,
  opts: { fetch?: typeof fetch; timeoutMs?: number; now?: () => number } = {},
): HolidaySource {
  const doFetch = opts.fetch ?? fetch;
  const now = opts.now ?? Date.now;
  const lists = new Map<string, { at: number; value: Promise<unknown> }>();

  async function get(path: string, params: Record<string, string>): Promise<unknown> {
    const res = await doFetch(`${base}/${path}?${new URLSearchParams(params)}`, {
      headers: { Accept: "application/json" },
      signal: timeoutSignal(opts.timeoutMs ?? REQUEST_TIMEOUT_MS),
    });
    if (!res.ok) throw new Error(`OpenHolidays answered ${res.status}`);
    return res.json();
  }

  /** A list kept for a day; a failed request isn't kept. */
  function kept<T>(key: string, load: () => Promise<T>): Promise<T> {
    const hit = lists.get(key);
    if (hit && now() - hit.at < LISTS_TTL_MS) return hit.value as Promise<T>;
    const value = load();
    lists.set(key, { at: now(), value });
    value.catch(() => lists.get(key)?.value === value && lists.delete(key));
    return value;
  }

  return {
    countries: () => kept("countries", async () => parseCountries(await get("Countries", {}))),
    subdivisions: (country) =>
      kept(`subdivisions:${country}`, async () => parseSubdivisions(await get("Subdivisions", { countryIsoCode: country }))),
    holidays: async (country, kind, year) =>
      parseHolidays(
        await get(kind === "public" ? "PublicHolidays" : "SchoolHolidays", {
          countryIsoCode: country,
          validFrom: `${year}-01-01`,
          validTo: addDays(`${year + 1}-01-01`, -1),
        }),
        kind,
      ),
  };
}

const sources = new Map<string, HolidaySource>();

/** The server's source (one per base URL, so its lists are shared), or null when it's off. */
export function defaultHolidaySource(env: Record<string, string | undefined> = process.env): HolidaySource | null {
  const base = holidaysUrl(env);
  if (!base) return null;
  let source = sources.get(base);
  if (!source) sources.set(base, (source = openHolidaysSource(base)));
  return source;
}
