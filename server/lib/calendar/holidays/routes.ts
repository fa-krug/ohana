// The holiday import's routes of the family API (with the calendar's, so never turned off):
//
// GET /holidays                       the settings (members) → HolidaysDto
// PUT /holidays {public?, school?, region?}   changes them (editors); region null: from the
//                                     home address, a code ("DE-BY"): fixed → HolidaysDto
// GET /holidays/regions[?country=DE]  the countries, or the country's subdivisions (members),
//                                     named in the caller's language; 502 when OpenHolidays
//                                     can't be reached

import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, readBody } from "@/lib/api/http";
import { homeOf } from "@/lib/digest/geo";
import { localDay } from "@/lib/notifications/daily";
import { isRegionCode, pickName, type Subdivision } from "./openholidays";
import { regionKey } from "./region";
import { getHolidaySettings, type HolidaySettings, holidaysDto, kindsOn, saveHolidaySettings } from "./settings";
import { type HolidaysEnv, pruneHolidays, resolveRegion } from "./sync";

/** How long PUT waits for the region (detected or named) before leaving it to the worker. */
const INLINE_TIMEOUT_MS = 5000;

function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  return Promise.race([
    p,
    new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error("timeout")), ms);
    }),
  ]).finally(() => clearTimeout(timer));
}

const langOf = (ctx: Ctx) => ctx.principal?.preferredLanguage ?? "en";

function cleanFlag(v: unknown, field: string): boolean | undefined {
  if (v === undefined) return undefined;
  if (typeof v !== "boolean") throw new HttpError(400, `${field} must be true or false`);
  return v;
}

/** `region`: undefined (unchanged), null (from the home address) or a code. */
function cleanRegion(v: unknown): string | null | undefined {
  if (v === undefined || v === null) return v;
  const code = typeof v === "string" ? v.trim().toUpperCase() : v;
  if (!isRegionCode(code)) throw new HttpError(400, 'region must be a region code like "DE-BY", or null');
  return code;
}

/** Routes /holidays[/regions]; null for anything else. */
export function handleHolidays(env: HolidaysEnv) {
  return (ctx: Ctx): Promise<Response> | null => {
    const { rest, method } = ctx;
    if (rest[0] !== "holidays") return null;
    if (rest.length === 1) {
      if (method === "GET") return read(ctx, env);
      if (method === "PUT") return update(ctx, env);
      return Promise.reject(new HttpError(405, "Method not allowed"));
    }
    if (rest.length === 2 && rest[1] === "regions") {
      return method === "GET" ? regions(ctx, env) : Promise.reject(new HttpError(405, "Method not allowed"));
    }
    return Promise.reject(new HttpError(404, "Not found"));
  };
}

const answer = (ctx: Ctx, env: HolidaysEnv, s: HolidaySettings) => json(holidaysDto(s, langOf(ctx), !!env.source));

async function read(ctx: Ctx, env: HolidaysEnv): Promise<Response> {
  const { family } = await ctx.load("view");
  return answer(ctx, env, getHolidaySettings(ctx.db, family.id));
}

async function update(ctx: Ctx, env: HolidaysEnv): Promise<Response> {
  const { family } = await ctx.load("edit");
  const { db, now } = ctx;
  const body = await readBody(ctx.req);
  const pub = cleanFlag(body.public, "public");
  const school = cleanFlag(body.school, "school");
  const region = cleanRegion(body.region);
  const s = getHolidaySettings(db, family.id);
  const set: Partial<HolidaySettings> = { requestedAt: now, status: null };
  if (pub !== undefined) set.publicHolidays = pub;
  if (school !== undefined) set.schoolHolidays = school;
  if (region === null && !s.regionAuto) Object.assign(set, { regionAuto: true, regionFrom: null });
  if (region && (s.regionAuto || region !== s.region)) {
    Object.assign(set, { regionAuto: false, region, regionFrom: null, regionNames: null });
  }
  saveHolidaySettings(db, family.id, set);
  const after = getHolidaySettings(db, family.id);
  // The region (detected while something is imported, or a fixed one's name) now, if it
  // doesn't take long; else the worker finds it.
  if (env.source) {
    const home = after.regionAuto && kindsOn(after).length ? homeOf(db, family.id) : null;
    const stale = after.regionAuto ? home && regionKey(home) !== after.regionFrom : after.region && !after.regionNames;
    if (stale) await withTimeout(resolveRegion(db, env, family.id), INLINE_TIMEOUT_MS).catch(() => undefined);
  }
  // Kinds turned off and an old region's days go at once.
  await pruneHolidays(db, family.id, localDay(now), now);
  return answer(ctx, env, getHolidaySettings(db, family.id));
}

type RegionDto = { code: string; name: string; children?: RegionDto[] };

const byName = (a: RegionDto, b: RegionDto) => a.name.localeCompare(b.name);

function subdivisionDto(s: Subdivision, lang: string): RegionDto {
  return {
    code: s.code,
    name: pickName(s.names, lang) || s.code,
    ...(s.children.length ? { children: s.children.map((c) => subdivisionDto(c, lang)).sort(byName) } : {}),
  };
}

async function regions(ctx: Ctx, env: HolidaysEnv): Promise<Response> {
  await ctx.load("view");
  if (!env.source) throw new HttpError(404, "Holidays are turned off on this server");
  const lang = langOf(ctx);
  const country = ctx.url.searchParams.get("country")?.trim().toUpperCase();
  if (country !== undefined && !/^[A-Z]{2}$/.test(country)) throw new HttpError(400, "country must be a country code like DE");
  try {
    if (!country) {
      return json((await env.source.countries()).map((c) => ({ code: c.code, name: pickName(c.names, lang) || c.code })).sort(byName));
    }
    return json((await env.source.subdivisions(country)).map((s) => subdivisionDto(s, lang)).sort(byName));
  } catch (e) {
    console.warn("[holidays] regions failed:", e instanceof Error ? e.message : e);
    throw new HttpError(502, "The holiday service can't be reached");
  }
}
