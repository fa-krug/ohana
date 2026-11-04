// The holiday import's settings and what requests read: the settings as the app sees them, the
// holidays of a range from the cache (requests never reach OpenHolidays) and the hooks other
// modules call (the home address changed, the family file replaced the entries).

import { and, eq, inArray } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { holidayCache, holidayDays, holidaySettings } from "@/lib/db/schema";
import { type CachedHoliday, type HolidayKind, holidayDaysIn, pickName } from "./openholidays";

export type HolidaySettings = typeof holidaySettings.$inferSelect;

export type HolidayStatus = "ok" | "pending" | "no_address" | "unsupported" | "failed" | "off";

/** The settings of a family that has none yet: nothing imported, the region from the home. */
export function defaultSettings(familyId: string): HolidaySettings {
  return {
    familyId,
    publicHolidays: false,
    schoolHolidays: false,
    region: null,
    regionAuto: true,
    regionFrom: null,
    regionNames: null,
    syncedRegion: null,
    importFrom: null,
    requestedAt: null,
    syncedAt: null,
    status: null,
  };
}

export function getHolidaySettings(db: Db, familyId: string): HolidaySettings {
  return db.select().from(holidaySettings).where(eq(holidaySettings.familyId, familyId)).get() ?? defaultSettings(familyId);
}

/** Writes some of the settings (the row is created with the defaults). */
export function saveHolidaySettings(db: Pick<Db, "insert">, familyId: string, set: Partial<Omit<HolidaySettings, "familyId">>): void {
  db.insert(holidaySettings)
    .values({ ...defaultSettings(familyId), ...set })
    .onConflictDoUpdate({ target: holidaySettings.familyId, set })
    .run();
}

/** The kinds the family imports. */
export function kindsOn(s: HolidaySettings): HolidayKind[] {
  return [...(s.publicHolidays ? (["public"] as const) : []), ...(s.schoolHolidays ? (["school"] as const) : [])];
}

/** What GET / PUT /holidays answer. */
export interface HolidaysDto {
  public: boolean;
  school: boolean;
  auto: boolean;
  region: { code: string; name: string } | null;
  status: HolidayStatus;
  syncedAt: string | null;
}

function parseNames(raw: string | null): Record<string, string> {
  try {
    const v = raw ? JSON.parse(raw) : {};
    return v && typeof v === "object" ? v : {};
  } catch {
    return {};
  }
}

/** The settings for the app, the region named in `lang`. `enabled`: the server imports at all
 *  (HOLIDAYS_URL). */
export function holidaysDto(s: HolidaySettings, lang: string, enabled: boolean): HolidaysDto {
  let status: HolidayStatus;
  if (!enabled || kindsOn(s).length === 0) status = "off";
  else if (s.status === "failed") status = "failed";
  else if (s.requestedAt) status = "pending";
  else status = (s.status as HolidayStatus | null) ?? "pending";
  return {
    public: s.publicHolidays,
    school: s.schoolHolidays,
    auto: s.regionAuto,
    region: s.region ? { code: s.region, name: pickName(parseNames(s.regionNames), lang) || s.region } : null,
    status,
    syncedAt: s.syncedAt?.toISOString() ?? null,
  };
}

/** Asks the worker for a sync of the family's holidays (when it has settings). */
export function requestHolidaySync(db: Db, familyId: string, now: Date): void {
  db.update(holidaySettings).set({ requestedAt: now }).where(eq(holidaySettings.familyId, familyId)).run();
}

/** The home address changed: a sync, when the region follows it and something is imported. */
export function homeChanged(db: Db, familyId: string, now: Date): void {
  const s = getHolidaySettings(db, familyId);
  if (s.regionAuto && kindsOn(s).length) requestHolidaySync(db, familyId, now);
}

/** The family file replaced all entries: nothing the import wrote is left, so it starts over. */
export function entriesReplaced(db: Db, familyId: string, now: Date): void {
  db.delete(holidayDays).where(eq(holidayDays.familyId, familyId)).run();
  requestHolidaySync(db, familyId, now);
}

/** The cached holidays of a country, kind and year, or null when none are cached. */
export function cachedHolidays(db: Db, country: string, kind: HolidayKind, year: number): { list: CachedHoliday[]; fetchedAt: Date } | null {
  const row = db
    .select()
    .from(holidayCache)
    .where(and(eq(holidayCache.country, country), eq(holidayCache.kind, kind), eq(holidayCache.year, year)))
    .get();
  if (!row) return null;
  try {
    const list = JSON.parse(row.data);
    return Array.isArray(list) ? { list, fetchedAt: row.fetchedAt } : null;
  } catch {
    return null;
  }
}

export type HolidayDay = { name: string; kind: HolidayKind };

const MAX_YEARS = 4;

/** GET /families/{id}'s `holidays`: day → the holidays of the kinds the family imports in its
 *  region, from `from` to `to`, named in `lang` (from the cache only). */
export function holidaysByDay(
  db: Db,
  familyId: string,
  range: { from: string; to: string },
  lang: string,
  enabled: boolean,
): Record<string, HolidayDay[]> {
  const out: Record<string, HolidayDay[]> = {};
  const s = getHolidaySettings(db, familyId);
  if (!enabled || !s.region) return out;
  const country = s.region.slice(0, 2);
  const first = Number(range.from.slice(0, 4));
  const last = Math.min(Number(range.to.slice(0, 4)), first + MAX_YEARS - 1);
  for (const kind of kindsOn(s)) {
    const list: CachedHoliday[] = [];
    for (let year = first; year <= last; year++) list.push(...(cachedHolidays(db, country, kind, year)?.list ?? []));
    for (const [day, holidays] of [...holidayDaysIn(list, s.region, country, range.from, range.to)].sort(([a], [b]) => a.localeCompare(b))) {
      const on = (out[day] ??= []);
      for (const h of holidays) {
        const name = pickName(h.names, lang);
        if (!on.some((o) => o.kind === kind && o.name === name)) on.push({ name, kind });
      }
    }
  }
  return out;
}

/** The days the import wrote for the family, of `kinds`. */
export function recordedDays(db: Pick<Db, "select">, familyId: string, kinds: HolidayKind[]): { kind: HolidayKind; day: string }[] {
  if (!kinds.length) return [];
  return db
    .select({ kind: holidayDays.kind, day: holidayDays.day })
    .from(holidayDays)
    .where(and(eq(holidayDays.familyId, familyId), inArray(holidayDays.kind, kinds)))
    .all() as { kind: HolidayKind; day: string }[];
}
