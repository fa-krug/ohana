// The assistant's appointment tools: the family's Doctolib / jameda searches (list with their
// earliest finds, create one — "find a dermatologist before June" —, change, turn on or off,
// run now), a found slot's details, and marking a slot as booked (a calendar event, phase 7).
// Specialities come from Doctolib's autocomplete and jameda's term list, places from the
// Photon geocoder (lib/appointments; each look-up with a timeout); the place defaults to the
// family's home address. Runs stay in the worker: "run now" only queues the search.

import { and, eq } from "drizzle-orm";
import { HttpError } from "@/lib/api/http";
import { diffDays, isValidDate } from "@/lib/calendar/dates";
import { findBooking, publicEvent } from "@/lib/calendar/events";
import { apptSearches, families, notificationChannels } from "@/lib/db/schema";
import type { Db } from "@/lib/db";
import { bookSlot } from "@/lib/appointments/booking";
import { haversineKm } from "@/lib/appointments/distance";
import { DoctolibClient } from "@/lib/appointments/doctolib/client";
import { suggestLocations } from "@/lib/appointments/geocoding";
import { type JamedaTerm, suggestJamedaTerms } from "@/lib/appointments/jameda/terms";
import { type SearchInput, searchInputSchema } from "@/lib/appointments/schema";
import {
  createSearch, requestRun, type SearchRow, searchInputOf, updateSearch,
} from "@/lib/appointments/searches";
import { getSlotDetail, listSearchesWithLatest, type SearchListItem } from "@/lib/appointments/serialize";
import { fitting, type Lookups, type Tool, type ToolContext, type UndoStep } from "./common";

const LOOKUP_MS = 15_000;
const SHOWN_DOCTORS = 5;

const PHRASES = {
  en: {
    created: (n: string) => `Added the appointment search “${n}”`,
    changed: (n: string) => `Changed the appointment search “${n}”`,
    booked: (d: string, day: string) => `Booked ${d} on ${day}`,
  },
  de: {
    created: (n: string) => `Terminsuche „${n}“ angelegt`,
    changed: (n: string) => `Terminsuche „${n}“ geändert`,
    booked: (d: string, day: string) => `${d} am ${day} als gebucht eingetragen`,
  },
};

/** Fails after `ms` instead of waiting on a slow site. */
function withTimeout<T>(p: Promise<T>, ms = LOOKUP_MS): Promise<T> {
  return Promise.race([
    p,
    new Promise<T>((_, reject) => setTimeout(() => reject(new HttpError(504, "The look-up took too long")), ms)),
  ]);
}

export const defaultLookups: Lookups = {
  async doctolibSpecialities(query) {
    const client = new DoctolibClient("https://www.doctolib.de/search", 0);
    return client.parseSpecialitySuggestions(await client.suggestSpecialities(query));
  },
  places: (query) => suggestLocations(query),
};

function lookups(ctx: ToolContext): Lookups {
  return { ...defaultLookups, ...ctx.lookups };
}

/** Doctolib's specialities for the words, [] when Doctolib can't be reached. */
async function doctolibFor(ctx: ToolContext, query: string) {
  try {
    return await withTimeout(lookups(ctx).doctolibSpecialities(query));
  } catch {
    return null;
  }
}

const str = (v: unknown) => (typeof v === "string" ? v.trim() : "");
const nowOf = (ctx: ToolContext) => ctx.now?.() ?? new Date();
const todayOf = (ctx: ToolContext) => ctx.today ?? nowOf(ctx).toISOString().slice(0, 10);
const enc = encodeURIComponent;
const pad = (n: number) => String(n).padStart(2, "0");
/** A moment as the server's wall-clock day and time (the calendar has no time zones). */
const localDay = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const localTime = (d: Date) => `${pad(d.getHours())}:${pad(d.getMinutes())}`;

function actor(ctx: ToolContext) {
  if (!ctx.userId) throw new HttpError(403, "Changes need a signed-in user");
  return { id: ctx.userId };
}

/** A search of the family by id or name. */
function findSearch(db: Db, familyId: string, ref: unknown): SearchRow {
  const r = str(ref);
  if (!r) throw new HttpError(400, "search is required (its id or name)");
  const rows = db.select().from(apptSearches).where(eq(apptSearches.familyId, familyId)).all();
  const found = rows.find((s) => s.id === r) ??
    rows.find((s) => s.name.toLowerCase() === r.toLowerCase()) ??
    rows.find((s) => s.name.toLowerCase().includes(r.toLowerCase()));
  if (!found) throw new HttpError(404, `No appointment search "${r}"`);
  return found;
}

function searchView(s: SearchListItem, familyId: string) {
  return {
    id: s.id,
    name: s.name,
    sources: s.sources,
    doctolib: s.specialityLabel || s.specialitySlug || null,
    jameda: s.jamedaSpecialityLabel || null,
    place: s.locationLabel,
    insurance: s.insuranceSector || "any",
    days: s.dayLimit,
    enabled: s.enabled,
    every: s.scheduleType === "MINUTES" ? `${s.scheduleMinutes} min` : s.scheduleType === "CRON" ? `cron ${s.cron}` : s.scheduleType,
    notifyOnlyEarlier: s.notifyOnlyEarlier,
    notifyApp: s.notifyApp,
    runRequested: s.runRequested,
    lastRun: s.latestRun
      ? { status: s.latestRun.status, at: s.latestRun.startedAt, slots: s.latestRun.slotsFound, error: s.latestRun.errorMessage || undefined }
      : null,
    earliest: s.doctors.slice(0, SHOWN_DOCTORS).map((d) => ({
      resultId: d.resultId,
      doctor: d.doctorName,
      slot: d.slot,
      localDay: localDay(new Date(d.slot)),
      localTime: localTime(new Date(d.slot)),
      onlyNextSlot: d.isNextSlot || undefined,
      practice: d.practiceName || undefined,
      city: d.practiceCity || undefined,
      motive: d.motiveLabel || undefined,
      source: d.source,
    })),
    moreDoctors: Math.max(0, s.doctors.length - SHOWN_DOCTORS) || undefined,
    page: `/f/${familyId}/appointments/${s.id}`,
  };
}

/** The best Doctolib speciality for the words: the same label, else the first. */
function pickDoctolib(list: { slug: string; label: string }[], query: string) {
  const q = query.toLowerCase();
  return list.find((s) => s.label.toLowerCase() === q) ?? list.find((s) => s.label.toLowerCase().includes(q)) ?? list[0] ?? null;
}

/** The best jameda term: a profession (Fachgebiet) first. */
function pickJameda(query: string): JamedaTerm | null {
  const list = suggestJamedaTerms(query, 50);
  return list.find((t) => t.type === "specialization") ?? list[0] ?? null;
}

/** The days from today to `before` (the last day a slot may be on), or `days`. */
function dayLimitOf(args: Record<string, unknown>, ctx: ToolContext): number | undefined {
  if (args.before !== undefined && args.before !== null && args.before !== "") {
    if (!isValidDate(args.before)) throw new HttpError(400, "before must be YYYY-MM-DD");
    const n = diffDays(todayOf(ctx), args.before as string);
    if (n < 1) throw new HttpError(400, "before must be after today");
    return Math.min(365, n);
  }
  if (args.days !== undefined && args.days !== null) {
    const n = Number(args.days);
    if (!Number.isInteger(n) || n < 1 || n > 365) throw new HttpError(400, "days must be 1 to 365");
    return n;
  }
  return undefined;
}

async function placeOf(ctx: ToolContext, place: string) {
  let found;
  try {
    found = await withTimeout(lookups(ctx).places(place));
  } catch {
    throw new HttpError(502, "The place search can't be reached right now");
  }
  if (!found.length) throw new HttpError(404, `No place found for "${place}"`);
  return { latitude: found[0].latitude, longitude: found[0].longitude, label: found[0].label };
}

function homeOf(db: Db, familyId: string) {
  const f = db
    .select({ address: families.homeAddress, lat: families.homeLat, lng: families.homeLng })
    .from(families)
    .where(eq(families.id, familyId))
    .get();
  return f?.address && f.lat !== null && f.lng !== null ? { latitude: String(f.lat), longitude: String(f.lng), label: f.address } : null;
}

const searchProps = {
  name: { type: "string" },
  before: { type: "string", description: "YYYY-MM-DD: only slots up to this day (e.g. 2027-05-31 for \"before June\")" },
  days: { type: "integer", description: "Or: only slots in the next N days (1–365)" },
  place: { type: "string", description: "Where to search around (a town or address); default the family's home address" },
  insurance: { type: "string", enum: ["any", "public", "private"], description: "Bookable for statutory (public) or private insurance" },
  kidsFriendly: { type: "boolean", description: "jameda: only child-friendly practices" },
  everyMinutes: { type: "integer", description: "How often to look (minutes, default 30)" },
  notifyOnlyEarlier: { type: "boolean", description: "Notify only when a slot beats the earliest one seen so far" },
  notifyApp: { type: "boolean", description: "Also notify the family members' Ohana apps (push); default true" },
};

/** The search's input with the asked-for changes of the shared fields. */
async function applyCommon(input: SearchInput, args: Record<string, unknown>, ctx: ToolContext) {
  if (args.name !== undefined) input.name = str(args.name).slice(0, 200);
  const days = dayLimitOf(args, ctx);
  if (days !== undefined) input.dayLimit = days;
  if (str(args.place)) {
    const p = await placeOf(ctx, str(args.place));
    input.latitude = p.latitude;
    input.longitude = p.longitude;
    input.locationLabel = p.label;
  }
  if (args.insurance !== undefined) {
    const i = args.insurance === "public" || args.insurance === "private" ? args.insurance : "";
    input.insuranceSector = i;
    input.jamedaInsuranceType = i === "public" ? "government" : i === "private" ? "private" : "";
  }
  if (typeof args.kidsFriendly === "boolean") input.jamedaKidsFriendly = args.kidsFriendly;
  if (args.everyMinutes !== undefined) {
    const n = Number(args.everyMinutes);
    if (!Number.isInteger(n) || n < 5 || n > 1440) throw new HttpError(400, "everyMinutes must be 5 to 1440");
    input.scheduleType = "MINUTES";
    input.scheduleMinutes = n;
  }
  if (typeof args.notifyOnlyEarlier === "boolean") input.notifyOnlyEarlier = args.notifyOnlyEarlier;
  if (typeof args.notifyApp === "boolean") input.notifyApp = args.notifyApp;
}

export const appointmentTools: Record<string, Tool> = {
  list_appointment_searches: {
    spec: {
      name: "list_appointment_searches",
      description:
        "Lists the family's doctor appointment searches (Doctolib / jameda watchers) with their settings, last run and the earliest slot per doctor found (resultId for get_appointment_slot / book_appointment_slot; times are UTC, localDay/localTime the family's).",
      parameters: { type: "object", properties: {} },
    },
    async run(_args, { db, familyId }) {
      const list = listSearchesWithLatest(db, familyId).map((s) => searchView(s, familyId));
      const shown = fitting({}, list);
      return { result: { searches: shown, ...(shown.length < list.length ? { more: list.length - shown.length } : {}) }, summary: `${list.length} searches` };
    },
  },

  find_doctor_specialities: {
    spec: {
      name: "find_doctor_specialities",
      description:
        "Looks up the specialities a search can use for some words (German works best, e.g. Hautarzt, Dermatologe, Kinderarzt, Zahnarzt): Doctolib's (slug + label; null when Doctolib can't be reached) and jameda's terms (profession, service or condition).",
      parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] },
    },
    async run(args, ctx) {
      const q = str(args.query);
      if (!q) throw new HttpError(400, "query is required");
      const doctolib = await doctolibFor(ctx, q);
      const jameda = suggestJamedaTerms(q, 10);
      return { result: { doctolib: doctolib?.slice(0, 10) ?? null, jameda }, summary: q };
    },
  },

  create_appointment_search: {
    write: true,
    spec: {
      name: "create_appointment_search",
      description:
        'Creates an appointment search that the worker runs regularly; it notifies the family\'s channels when slots show up. speciality: words like "Hautarzt" / "Dermatologe" (German works best); the best Doctolib speciality and jameda profession are picked (or pass doctolibSpeciality / jamedaTerm slugs from find_doctor_specialities). It searches around the family\'s home address unless place is given, for slots up to "before" (or the next "days"; default 14).',
      parameters: {
        type: "object",
        properties: {
          speciality: { type: "string" },
          doctolibSpeciality: { type: "string", description: "A Doctolib slug" },
          jamedaTerm: { type: "string", description: "A jameda term slug" },
          sources: { type: "string", enum: ["doctolib", "jameda", "both"], description: "Default: both, where found" },
          ...searchProps,
        },
        required: ["speciality"],
      },
    },
    async run(args, ctx) {
      const { db, familyId, lang } = ctx;
      const words = str(args.speciality);
      if (!words) throw new HttpError(400, "speciality is required");
      const want = args.sources === "doctolib" || args.sources === "jameda" ? args.sources : "both";
      let doctolib: { slug: string; label: string } | null = null;
      if (want !== "jameda") {
        if (str(args.doctolibSpeciality)) {
          doctolib = { slug: str(args.doctolibSpeciality), label: words };
          const list = await doctolibFor(ctx, words);
          doctolib = list?.find((s) => s.slug === doctolib!.slug) ?? doctolib;
        } else {
          doctolib = pickDoctolib((await doctolibFor(ctx, words)) ?? [], words);
        }
      }
      let jameda: JamedaTerm | null = null;
      if (want !== "doctolib") {
        jameda = str(args.jamedaTerm)
          ? (suggestJamedaTerms(str(args.jamedaTerm), 50).find((t) => t.slug === str(args.jamedaTerm)) ?? null)
          : pickJameda(words);
      }
      if (want === "doctolib" && !doctolib) throw new HttpError(404, `Doctolib knows no speciality for "${words}" (or can't be reached)`);
      if (want === "jameda" && !jameda) throw new HttpError(404, `jameda knows no term for "${words}"`);
      if (!doctolib && !jameda) {
        throw new HttpError(404, `No speciality found for "${words}": try German words, or find_doctor_specialities`);
      }
      const place = str(args.place) ? await placeOf(ctx, str(args.place)) : homeOf(db, familyId);
      if (!place) {
        throw new HttpError(400, "The family has no home address (Settings → Household): ask the user where to search");
      }
      const channelIds = db
        .select({ id: notificationChannels.id })
        .from(notificationChannels)
        .where(and(eq(notificationChannels.familyId, familyId), eq(notificationChannels.enabled, true)))
        .all()
        .map((c) => c.id);
      const input = searchInputSchema.parse({
        name: str(args.name) || doctolib?.label || jameda?.label || words,
        sources: doctolib && jameda ? "both" : doctolib ? "doctolib" : "jameda",
        specialitySlug: doctolib?.slug ?? "",
        specialityLabel: doctolib?.label ?? "",
        jamedaSpecialitySlug: jameda?.slug ?? "",
        jamedaSpecialityLabel: jameda?.label ?? "",
        jamedaSpecialityType: jameda?.type ?? "leistung",
        latitude: place.latitude,
        longitude: place.longitude,
        locationLabel: place.label,
        channelIds,
      });
      await applyCommon(input, { ...args, name: args.name ?? input.name, place: undefined }, ctx);
      const { id } = createSearch(db, actor(ctx), familyId, searchInputSchema.parse(input), nowOf(ctx));
      return {
        result: {
          ok: true,
          id,
          name: input.name,
          doctolib: doctolib?.label ?? null,
          jameda: jameda?.label ?? null,
          place: place.label,
          days: input.dayLimit,
          notifies: channelIds.length ? `${channelIds.length} channels` : "no notification channel is set up (Settings → Household)",
          page: `/f/${familyId}/appointments/${id}`,
          note: "The worker runs it within the next minutes (run_appointment_search to start now).",
        },
        summary: input.name,
        change: {
          kind: "appointments",
          summary: PHRASES[lang].created(input.name),
          undo: [{ method: "DELETE", path: `/appointments/searches/${enc(id)}` }],
        },
      };
    },
  },

  change_appointment_search: {
    write: true,
    spec: {
      name: "change_appointment_search",
      description:
        "Changes an appointment search: turn it on or off (enabled), rename, another deadline (before / days), place, insurance, how often, notify only earlier. Fields left out stay.",
      parameters: {
        type: "object",
        properties: { search: { type: "string", description: "Its id or name" }, enabled: { type: "boolean" }, ...searchProps },
        required: ["search"],
      },
    },
    async run(args, ctx) {
      const { db, familyId, lang } = ctx;
      const s = findSearch(db, familyId, args.search);
      const before = searchInputOf(db, s);
      const input: SearchInput = { ...before, channelIds: [...before.channelIds] };
      if (typeof args.enabled === "boolean") input.enabled = args.enabled;
      await applyCommon(input, args, ctx);
      updateSearch(db, actor(ctx), familyId, s.id, searchInputSchema.parse(input), nowOf(ctx));
      return {
        result: { ok: true, id: s.id, name: input.name, enabled: input.enabled, days: input.dayLimit, place: input.locationLabel },
        summary: input.name,
        change: {
          kind: "appointments",
          summary: PHRASES[lang].changed(s.name),
          undo: [{ method: "PATCH", path: `/appointments/searches/${enc(s.id)}`, body: before }],
        },
      };
    },
  },

  run_appointment_search: {
    write: true,
    spec: {
      name: "run_appointment_search",
      description: "Runs an appointment search now (the worker starts it within a few seconds; read the results later with list_appointment_searches).",
      parameters: { type: "object", properties: { search: { type: "string" } }, required: ["search"] },
    },
    async run(args, ctx) {
      const s = findSearch(ctx.db, ctx.familyId, args.search);
      requestRun(ctx.db, actor(ctx), ctx.familyId, s.id, nowOf(ctx));
      return { result: { ok: true, queued: s.name }, summary: s.name };
    },
  },

  get_appointment_slot: {
    spec: {
      name: "get_appointment_slot",
      description: "Reads a found slot: the doctor, practice and address, the time, the booking link, the distance from home, and whether it is marked as booked.",
      parameters: {
        type: "object",
        properties: { search: { type: "string" }, resultId: { type: "integer" } },
        required: ["search", "resultId"],
      },
    },
    async run(args, { db, familyId }) {
      const s = findSearch(db, familyId, args.search);
      const d = getSlotDetail(db, familyId, s.id, Number(args.resultId));
      if (!d) throw new HttpError(404, "Slot not found (results go after 30 days)");
      const lat = Number(d.slot.practiceLatitude), lng = Number(d.slot.practiceLongitude);
      const km = d.homeLat !== null && d.homeLng !== null && d.slot.practiceLatitude && Number.isFinite(lat) && Number.isFinite(lng)
        ? Math.round(haversineKm(d.homeLat, d.homeLng, lat, lng) * 10) / 10
        : null;
      const booking = findBooking(db, familyId, s.id, d.slot.resultId);
      const at = new Date(d.slot.slot);
      return {
        result: {
          ...d.slot,
          localDay: localDay(at),
          localTime: localTime(at),
          search: d.searchName,
          kmFromHome: km,
          booked: booking ? publicEvent(booking) : null,
          page: `/f/${familyId}/appointments/${s.id}/slots/${d.slot.resultId}`,
        },
        summary: d.slot.doctorName,
      };
    },
  },

  book_appointment_slot: {
    write: true,
    spec: {
      name: "book_appointment_slot",
      description:
        "Marks a slot as booked once the user booked it with the practice (this doesn't book anything there): it becomes a calendar event with the doctor and address. date / start default to the slot's local day and time; stopSearch turns the search off.",
      parameters: {
        type: "object",
        properties: {
          search: { type: "string" },
          resultId: { type: "integer" },
          date: { type: "string", description: "YYYY-MM-DD" },
          start: { type: "string", description: "HH:MM" },
          end: { type: "string", description: "HH:MM" },
          person: { type: "string", description: "Who it is for: a family member's name" },
          note: { type: "string" },
          stopSearch: { type: "boolean" },
        },
        required: ["search", "resultId"],
      },
    },
    async run(args, ctx) {
      const { db, familyId, lang } = ctx;
      const s = findSearch(db, familyId, args.search);
      const resultId = Number(args.resultId);
      const d = getSlotDetail(db, familyId, s.id, resultId);
      if (!d) throw new HttpError(404, "Slot not found (results go after 30 days)");
      const before = searchInputOf(db, s);
      const at = new Date(d.slot.slot);
      const stop = args.stopSearch === true;
      const event = bookSlot(db, actor(ctx), familyId, s.id, resultId, {
        date: str(args.date) || localDay(at),
        start: str(args.start) || localTime(at),
        end: str(args.end) || null,
        person: str(args.person),
        note: str(args.note),
        stopSearch: stop,
      }, nowOf(ctx));
      const undo: UndoStep[] = [{ method: "DELETE", path: `/events/${enc(event.id)}` }];
      if (stop && s.enabled) undo.push({ method: "PATCH", path: `/appointments/searches/${enc(s.id)}`, body: before });
      return {
        result: { ok: true, event: publicEvent(event), searchStopped: stop },
        summary: `${event.day} ${event.start ?? ""}`.trim(),
        change: {
          kind: "events",
          summary: PHRASES[lang].booked(event.title, event.day),
          undo,
        },
      };
    },
  },
};
