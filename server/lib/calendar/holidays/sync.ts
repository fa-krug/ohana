// The holiday import (worker): a family's public and / or school holidays of its region become
// day entries of per-year types (`holiday`, the preset; `school-holidays`), from Jan 1 of this
// year to Dec 31 of the next. What it wrote is recorded in `holiday_days`, so a day the user
// deletes stays deleted and a day the source drops (from today on) goes again; a kind turned
// off or a new region removes the recorded days from today on, the past stays. A sync runs
// when `requested_at` is due (settings changed, the home moved, the family file was imported,
// once a day); a failed one is tried again after RETRY_MS. OpenHolidays' years are cached in
// `holiday_cache` for every family (CACHE_DAYS).

import { and, asc, eq, inArray, isNotNull, isNull, lt, lte, or } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { holidayCache, holidayDays, holidaySettings } from "@/lib/db/schema";
import { homeOf } from "@/lib/digest/geo";
import type { Lang } from "@/lib/i18n/config";
import { localDay } from "@/lib/notifications/daily";
import { familyLocale } from "@/lib/notifications/locale";
import { DrizzleCalendarStore, type Role, type TypeInput, type TypeRow } from "../store";
import { MAX_TYPES, newFamilyTypes } from "../vacation";
import {
  type CachedHoliday,
  defaultHolidaySource,
  HOLIDAY_KINDS,
  type HolidayKind,
  holidayDaysIn,
  type HolidaySource,
} from "./openholidays";
import { detectRegion, lookUpRegionNames, photonReverse, type ReverseLookup, regionKey } from "./region";
import { getHolidaySettings, kindsOn, recordedDays, saveHolidaySettings, cachedHolidays } from "./settings";

/** Days a cached year of holidays is used before it is fetched again. */
export const CACHE_DAYS = 7;
/** How long a failed sync waits before it is tried again. */
export const RETRY_MS = 10 * 60_000;
/** Families synced per round of the runner. */
const BATCH = 5;
const DAY_MS = 86_400_000;
const CHUNK = 500;

/** Where the holidays and the home's region come from (tests: fakes). `source` null: off. */
export interface HolidaysEnv {
  source: HolidaySource | null;
  reverse: ReverseLookup;
}

export function defaultHolidaysEnv(env: Record<string, string | undefined> = process.env): HolidaysEnv {
  return { source: defaultHolidaySource(env), reverse: photonReverse };
}

/** The type each kind's days go into, per year. */
export const HOLIDAY_TYPES: Record<HolidayKind, { id: string; role: Role; icon: string | null; name: (lang: Lang) => string }> = {
  public: {
    id: "holiday",
    role: "day_off",
    icon: null,
    name: (lang) => newFamilyTypes(undefined, lang).find((t) => t.id === "holiday")!.name,
  },
  school: {
    id: "school-holidays",
    role: "needs_cover",
    icon: "backpack",
    name: (lang) => (lang === "de" ? "Schulferien" : "School holidays"),
  },
};

/** The holidays of a country, kind and year: the cached copy while it's fresh, else fetched
 *  (a failed fetch falls back to an older copy; without one it throws). */
export async function holidayYear(
  db: Db,
  source: HolidaySource,
  country: string,
  kind: HolidayKind,
  year: number,
  now: Date,
): Promise<CachedHoliday[]> {
  const cached = cachedHolidays(db, country, kind, year);
  if (cached && now.getTime() - cached.fetchedAt.getTime() < CACHE_DAYS * DAY_MS) return cached.list;
  let list: CachedHoliday[];
  try {
    list = await source.holidays(country, kind, year);
  } catch (e) {
    if (cached) return cached.list;
    throw e;
  }
  const values = { data: JSON.stringify(list), fetchedAt: now };
  db.insert(holidayCache)
    .values({ country, kind, year, ...values })
    .onConflictDoUpdate({ target: [holidayCache.country, holidayCache.kind, holidayCache.year], set: values })
    .run();
  return list;
}

/** Brings the region up to date: detected again when it follows the home and the home moved
 *  (no home: none), named when it has no names yet. Throws when a service can't be reached. */
export async function resolveRegion(db: Db, env: HolidaysEnv, familyId: string): Promise<void> {
  const s = getHolidaySettings(db, familyId);
  const source = env.source;
  if (!source) return;
  if (s.regionAuto) {
    const home = homeOf(db, familyId);
    if (!home) {
      if (s.region || s.regionFrom) saveHolidaySettings(db, familyId, { region: null, regionFrom: null, regionNames: null });
      return;
    }
    const key = regionKey(home);
    if (key === s.regionFrom) return;
    const region = await detectRegion(source, env.reverse, home);
    const names = region ? await lookUpRegionNames(source, region) : null;
    saveHolidaySettings(db, familyId, { region, regionFrom: key, regionNames: names && JSON.stringify(names) });
    return;
  }
  if (s.region && !s.regionNames) {
    saveHolidaySettings(db, familyId, { regionNames: JSON.stringify(await lookUpRegionNames(source, s.region)) });
  }
}

/** Removes the entries of recorded days (only the import's type of their kind) and the records. */
async function removeRecorded(db: Db, store: DrizzleCalendarStore, familyId: string, days: { kind: HolidayKind; day: string }[]) {
  for (const kind of HOLIDAY_KINDS) {
    const list = days.filter((d) => d.kind === kind).map((d) => d.day);
    if (!list.length) continue;
    await store.removeEntries(familyId, list, [HOLIDAY_TYPES[kind].id]);
    for (let i = 0; i < list.length; i += CHUNK) {
      db.delete(holidayDays)
        .where(and(eq(holidayDays.familyId, familyId), eq(holidayDays.kind, kind), inArray(holidayDays.day, list.slice(i, i + CHUNK))))
        .run();
    }
  }
}

/** Takes back what no longer applies, without the network: the recorded days from `today` on
 *  of kinds turned off, and of every kind when the region changed (the new one is imported
 *  from `today` on, unless nothing was imported before). */
export async function pruneHolidays(db: Db, familyId: string, today: string, now = new Date()): Promise<void> {
  const s = getHolidaySettings(db, familyId);
  const regionChanged = s.region !== s.syncedRegion;
  const on = kindsOn(s);
  const kinds = HOLIDAY_KINDS.filter((k) => regionChanged || !on.includes(k));
  const store = new DrizzleCalendarStore(db, () => now);
  await removeRecorded(
    db,
    store,
    familyId,
    recordedDays(db, familyId, kinds).filter((d) => d.day >= today),
  );
  if (regionChanged) {
    const kept = recordedDays(db, familyId, [...HOLIDAY_KINDS]).length > 0;
    saveHolidaySettings(db, familyId, { syncedRegion: s.region, importFrom: kept ? today : null });
  }
}

/** The kind's type of `year` (made when missing: last year's copied, else the preset, at the
 *  end); false when the year has no room for another type. Never changes an existing type. */
async function ensureType(
  store: DrizzleCalendarStore,
  types: TypeRow[],
  familyId: string,
  kind: HolidayKind,
  year: number,
  lang: Lang,
): Promise<boolean> {
  const def = HOLIDAY_TYPES[kind];
  if (types.some((t) => t.year === year && t.id === def.id)) return true;
  const ofYear = types.filter((t) => t.year === year);
  if (ofYear.length >= MAX_TYPES) return false;
  const position = ofYear.reduce((m, t) => Math.max(m, t.position + 1), 0);
  const prev = types.find((t) => t.year === year - 1 && t.id === def.id);
  const type: TypeInput = prev
    ? { ...prev, year, position }
    : { family_id: familyId, year, id: def.id, name: def.name(lang), member_id: null, role: def.role, icon: def.icon, position, away: false };
  await store.upsertTypes([type]);
  types.push({ ...type, color: "" });
  return true;
}

/** Imports one kind in the family's region: adds the source's days not recorded yet (from
 *  `importFrom` on), removes recorded days from `today` on that the source no longer lists. */
async function importKind(
  db: Db,
  source: HolidaySource,
  store: DrizzleCalendarStore,
  types: TypeRow[],
  familyId: string,
  region: string,
  importFrom: string | null,
  kind: HolidayKind,
  today: string,
  lang: Lang,
  now: Date,
): Promise<void> {
  const year = Number(today.slice(0, 4));
  const from = `${year}-01-01`;
  const to = `${year + 1}-12-31`;
  const country = region.slice(0, 2);
  const list = [...(await holidayYear(db, source, country, kind, year, now)), ...(await holidayYear(db, source, country, kind, year + 1, now))];
  const days = holidayDaysIn(list, region, country, from, to);
  const recorded = new Set(recordedDays(db, familyId, [kind]).map((d) => d.day));
  const start = importFrom && importFrom > from ? importFrom : from;
  // A day the user already has in the type stays theirs: not recorded, so never taken back.
  const own = new Set(
    (await store.listEntries(familyId, start, to)).filter((e) => e.type_id === HOLIDAY_TYPES[kind].id).map((e) => e.day),
  );
  const add = [...days.keys()].filter((d) => d >= start && !recorded.has(d) && !own.has(d)).sort();
  for (const y of [year, year + 1]) {
    const ofYear = add.filter((d) => d.startsWith(`${y}-`));
    if (!ofYear.length || !(await ensureType(store, types, familyId, kind, y, lang))) continue;
    await store.addEntries(
      familyId,
      ofYear.map((day) => ({ day, type_id: HOLIDAY_TYPES[kind].id })),
    );
    for (let i = 0; i < ofYear.length; i += CHUNK) {
      db.insert(holidayDays)
        .values(ofYear.slice(i, i + CHUNK).map((day) => ({ familyId, kind, day })))
        .onConflictDoNothing()
        .run();
    }
  }
  const gone = [...recorded].filter((d) => d >= today && !days.has(d));
  await removeRecorded(
    db,
    store,
    familyId,
    gone.map((day) => ({ kind, day })),
  );
}

/** Syncs a family's holidays; sets its status and clears the request (a failure: status
 *  "failed", tried again after RETRY_MS). Never throws. */
export async function syncFamily(db: Db, env: HolidaysEnv, familyId: string, now = new Date(), today = localDay(now)): Promise<void> {
  const before = getHolidaySettings(db, familyId);
  const done = (set: Partial<typeof before>) =>
    db
      .update(holidaySettings)
      .set(set)
      .where(
        and(
          eq(holidaySettings.familyId, familyId),
          before.requestedAt ? eq(holidaySettings.requestedAt, before.requestedAt) : isNull(holidaySettings.requestedAt),
        ),
      )
      .run();
  try {
    const kinds = kindsOn(before);
    if (kinds.length && env.source) await resolveRegion(db, env, familyId);
    await pruneHolidays(db, familyId, today, now);
    const s = getHolidaySettings(db, familyId);
    let status: string | null = null;
    if (kinds.length && env.source) {
      if (!s.region) status = s.regionAuto && !homeOf(db, familyId) ? "no_address" : "unsupported";
      else if (!(await env.source.countries()).some((c) => c.code === s.region!.slice(0, 2))) status = "unsupported";
      else {
        const store = new DrizzleCalendarStore(db, () => now);
        const types = await store.listTypes(familyId);
        const lang = familyLocale(db, familyId);
        for (const kind of kinds) await importKind(db, env.source, store, types, familyId, s.region, s.importFrom, kind, today, lang, now);
        status = "ok";
      }
    }
    done({ status, syncedAt: now, requestedAt: null });
  } catch (e) {
    console.warn(`[holidays] sync of family ${familyId} failed:`, e instanceof Error ? e.message : e);
    done({ status: "failed", requestedAt: new Date(now.getTime() + RETRY_MS) });
  }
}

/** Once a day: asks for a sync of every family that imports something and wasn't synced today
 *  (server-local days). Returns how many. */
export function requestDailyHolidaySyncs(db: Db, now: Date): number {
  const midnight = new Date(now);
  midnight.setHours(0, 0, 0, 0);
  return db
    .update(holidaySettings)
    .set({ requestedAt: now })
    .where(
      and(
        isNull(holidaySettings.requestedAt),
        or(eq(holidaySettings.publicHolidays, true), eq(holidaySettings.schoolHolidays, true)),
        or(isNull(holidaySettings.syncedAt), lt(holidaySettings.syncedAt, midnight)),
      ),
    )
    .run().changes;
}

/** Picks up the families whose sync is due (a cheap indexed query, every worker loop) and
 *  syncs them one after the other, without blocking the loop; one round at a time. */
export class HolidayRunner {
  private running: Promise<void> | null = null;

  constructor(
    private readonly db: Db,
    private readonly env: HolidaysEnv = defaultHolidaysEnv(),
  ) {}

  /** Starts a round when families are due and none is running; whether it did. Never throws. */
  tick(now = new Date()): boolean {
    if (!this.env.source || this.running) return false;
    try {
      const due = this.db
        .select({ familyId: holidaySettings.familyId })
        .from(holidaySettings)
        .where(and(isNotNull(holidaySettings.requestedAt), lte(holidaySettings.requestedAt, now)))
        .orderBy(asc(holidaySettings.requestedAt))
        .limit(BATCH)
        .all();
      if (!due.length) return false;
      this.running = (async () => {
        for (const { familyId } of due) await syncFamily(this.db, this.env, familyId);
      })()
        .catch((e) => console.error("[holidays] round failed:", e))
        .finally(() => {
          this.running = null;
        });
      return true;
    } catch (e) {
      console.error("[holidays] tick failed:", e);
      return false;
    }
  }

  /** Resolves when the running round (if any) is done. */
  idle(): Promise<void> {
    return this.running ?? Promise.resolve();
  }

  async stop(ms: number): Promise<void> {
    if (this.running) await Promise.race([this.running, new Promise((r) => setTimeout(r, ms).unref())]);
  }
}
