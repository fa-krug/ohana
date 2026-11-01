import { and, desc, eq, ne } from "drizzle-orm";
import type { Db } from "@/lib/db";
import {
  apptIgnored as ignoredEntries,
  apptResults as appointmentResults,
  apptRuns as searchRuns,
  apptSearchChannels as searchChannels,
  apptSearches as searches,
  families,
} from "@/lib/db/schema";
import { ignoreKey } from "./sources/keys";
import type { SourceId } from "./sources/types";

export interface DoctorSlot {
  resultId: number;
  doctorName: string;
  doctorSubtitle: string;
  speciality: string;
  practiceName: string;
  motiveLabel: string;
  bookingUrl: string;
  slot: string; // ISO
  isNextSlot: boolean;
  practiceAddress: string;
  practiceCity: string;
  practiceZipcode: string;
  practiceLatitude: string;
  practiceLongitude: string;
  source: SourceId;
}

export interface RunSummary {
  id: string;
  status: string;
  startedAt: string;
  finishedAt: string | null;
  errorMessage: string;
  doctorsFound: number;
  doctorsMatched: number;
  slotsFound: number;
  notified: boolean;
  triggeredBy: string;
}

export interface IgnoredItem {
  id: number;
  doctorName: string;
  motiveLabel: string;
  providerSlug: string;
  motiveId: number;
}

export interface SearchListItem {
  id: string;
  name: string;
  sources: string;
  specialitySlug: string;
  specialityLabel: string;
  jamedaSpecialitySlug: string;
  jamedaSpecialityLabel: string;
  jamedaSpecialityType: string;
  jamedaInsuranceType: string;
  jamedaKidsFriendly: boolean;
  jamedaVideo: string;
  locationLabel: string;
  latitude: string;
  longitude: string;
  insuranceSector: string;
  dayLimit: number;
  maxPages: number;
  enabled: boolean;
  scheduleType: string;
  scheduleMinutes: number | null;
  cron: string;
  notifyOnlyEarlier: boolean;
  /** Also pushed to the app (phase 9). */
  notifyApp: boolean;
  lastRunAt: string | null;
  lastStatus: string;
  nextRunAt: string | null;
  /** "Run now" was asked for and the worker hasn't picked it up yet. */
  runRequested: boolean;
  channelIds: string[];
  latestRun: RunSummary | null;
  doctors: DoctorSlot[]; // earliest slot per doctor, sorted ascending
  ignored: IgnoredItem[];
}

type SearchRow = typeof searches.$inferSelect;

function iso(d: Date | null | undefined): string | null {
  return d ? d.toISOString() : null;
}

function toDoctorSlot(r: typeof appointmentResults.$inferSelect): DoctorSlot {
  return {
    resultId: r.id,
    doctorName: r.doctorName,
    doctorSubtitle: r.doctorSubtitle,
    speciality: r.speciality,
    practiceName: r.practiceName,
    motiveLabel: r.motiveLabel,
    bookingUrl: r.bookingUrl,
    slot: r.slotDatetime.toISOString(),
    isNextSlot: r.isNextSlot,
    practiceAddress: r.practiceAddress,
    practiceCity: r.practiceCity,
    practiceZipcode: r.practiceZipcode,
    practiceLatitude: r.practiceLatitude,
    practiceLongitude: r.practiceLongitude,
    source: (r.source ?? "doctolib") as SourceId,
  };
}

function toRunSummary(run: typeof searchRuns.$inferSelect): RunSummary {
  return {
    id: run.id,
    status: run.status,
    startedAt: run.startedAt.toISOString(),
    finishedAt: iso(run.finishedAt),
    errorMessage: run.errorMessage,
    doctorsFound: run.doctorsFound,
    doctorsMatched: run.doctorsMatched,
    slotsFound: run.slotsFound,
    notified: run.notified,
    triggeredBy: run.triggeredBy,
  };
}

function latestRunFor(db: Db, searchId: string): RunSummary | null {
  const run = db
    .select()
    .from(searchRuns)
    .where(eq(searchRuns.searchId, searchId))
    .orderBy(desc(searchRuns.startedAt))
    .get();
  return run ? toRunSummary(run) : null;
}

/**
 * The run whose results should be displayed. A freshly-started run is inserted as
 * RUNNING with no results yet, so while one is in flight we keep showing the last
 * completed run's results instead of blanking the list until the scrape finishes.
 */
function displayRunFor(db: Db, searchId: string): RunSummary | null {
  const run = db
    .select()
    .from(searchRuns)
    .where(and(eq(searchRuns.searchId, searchId), ne(searchRuns.status, "RUNNING")))
    .orderBy(desc(searchRuns.startedAt))
    .get();
  return run ? toRunSummary(run) : null;
}

/** Earliest slot per doctor for a run, excluding ignored (source, providerSlug, motiveId) pairs. */
function doctorsFor(db: Db, searchId: string, runId: string): DoctorSlot[] {
  const ignored = new Set(
    db
      .select({ source: ignoredEntries.source, slug: ignoredEntries.providerSlug, motiveId: ignoredEntries.motiveId })
      .from(ignoredEntries)
      .where(eq(ignoredEntries.searchId, searchId))
      .all()
      .map((e) => ignoreKey(e.source as SourceId, e.slug, e.motiveId)),
  );
  const rows = db
    .select()
    .from(appointmentResults)
    .where(eq(appointmentResults.runId, runId))
    .all()
    .filter((r) => !(r.providerSlug && r.motiveId !== null && ignored.has(ignoreKey((r.source ?? "doctolib") as SourceId, r.providerSlug, r.motiveId))));

  const byDoctor = new Map<string, DoctorSlot>();
  for (const r of rows) {
    const cur = byDoctor.get(r.doctorName);
    if (!cur || r.slotDatetime.getTime() < new Date(cur.slot).getTime()) {
      byDoctor.set(r.doctorName, toDoctorSlot(r));
    }
  }
  return [...byDoctor.values()].sort((a, b) => new Date(a.slot).getTime() - new Date(b.slot).getTime());
}

function channelIdsFor(db: Db, searchId: string): string[] {
  return db
    .select({ channelId: searchChannels.channelId })
    .from(searchChannels)
    .where(eq(searchChannels.searchId, searchId))
    .all()
    .map((r) => r.channelId);
}

function serializeSearch(db: Db, s: SearchRow): SearchListItem {
  const latestRun = latestRunFor(db, s.id);
  const displayRun = displayRunFor(db, s.id);
  return {
    id: s.id,
    name: s.name,
    sources: s.sources,
    specialitySlug: s.specialitySlug,
    specialityLabel: s.specialityLabel,
    jamedaSpecialitySlug: s.jamedaSpecialitySlug,
    jamedaSpecialityLabel: s.jamedaSpecialityLabel,
    jamedaSpecialityType: s.jamedaSpecialityType,
    jamedaInsuranceType: s.jamedaInsuranceType,
    jamedaKidsFriendly: s.jamedaKidsFriendly,
    jamedaVideo: s.jamedaVideo,
    locationLabel: s.locationLabel,
    latitude: s.latitude,
    longitude: s.longitude,
    insuranceSector: s.insuranceSector,
    dayLimit: s.dayLimit,
    maxPages: s.maxPages,
    enabled: s.enabled,
    scheduleType: s.scheduleType,
    scheduleMinutes: s.scheduleMinutes,
    cron: s.cron,
    notifyOnlyEarlier: s.notifyOnlyEarlier,
    notifyApp: s.notifyApp,
    lastRunAt: iso(s.lastRunAt),
    lastStatus: s.lastStatus,
    nextRunAt: s.scheduleType === "CRON" ? null : iso(s.nextRunAt),
    runRequested: s.runRequestedAt !== null,
    channelIds: channelIdsFor(db, s.id),
    latestRun,
    doctors: displayRun ? doctorsFor(db, s.id, displayRun.id) : [],
    ignored: ignoredFor(db, s.id),
  };
}

export function listSearchesWithLatest(db: Db, familyId: string): SearchListItem[] {
  const rows = db
    .select()
    .from(searches)
    .where(eq(searches.familyId, familyId))
    .orderBy(desc(searches.createdAt))
    .all();
  return rows.map((s) => serializeSearch(db, s));
}

function ignoredFor(db: Db, searchId: string): IgnoredItem[] {
  return db
    .select()
    .from(ignoredEntries)
    .where(eq(ignoredEntries.searchId, searchId))
    .orderBy(ignoredEntries.doctorName)
    .all()
    .map((e) => ({
      id: e.id,
      doctorName: e.doctorName,
      motiveLabel: e.motiveLabel,
      providerSlug: e.providerSlug,
      motiveId: e.motiveId,
    }));
}

export function getSearchDetail(db: Db, familyId: string, id: string): SearchListItem | null {
  const s = db.select().from(searches).where(eq(searches.id, id)).get();
  if (!s || s.familyId !== familyId) return null;
  return serializeSearch(db, s);
}

export interface RunWithResults {
  run: RunSummary;
  doctors: DoctorSlot[];
}

export function listRunsWithResults(
  db: Db,
  familyId: string,
  searchId: string,
): RunWithResults[] {
  const s = db.select().from(searches).where(eq(searches.id, searchId)).get();
  if (!s || s.familyId !== familyId) return [];
  const runs = db
    .select()
    .from(searchRuns)
    .where(eq(searchRuns.searchId, searchId))
    .orderBy(desc(searchRuns.startedAt))
    .all();
  return runs.map((run) => ({ run: toRunSummary(run), doctors: doctorsFor(db, searchId, run.id) }));
}

export interface SlotDetailData {
  slot: DoctorSlot;
  searchId: string;
  searchName: string;
  specialityLabel: string;
  insuranceSector: string;
  homeLat: number | null;
  homeLng: number | null;
}

export function getSlotDetail(
  db: Db,
  familyId: string,
  searchId: string,
  resultId: number,
): SlotDetailData | null {
  const s = db.select().from(searches).where(eq(searches.id, searchId)).get();
  if (!s || s.familyId !== familyId) return null;
  const r = db.select().from(appointmentResults).where(eq(appointmentResults.id, resultId)).get();
  if (!r) return null;
  const run = db
    .select({ searchId: searchRuns.searchId })
    .from(searchRuns)
    .where(eq(searchRuns.id, r.runId))
    .get();
  if (!run || run.searchId !== searchId) return null;
  const home = db
    .select({ lat: families.homeLat, lng: families.homeLng })
    .from(families)
    .where(eq(families.id, familyId))
    .get();
  return {
    slot: toDoctorSlot(r),
    searchId: s.id,
    searchName: s.name,
    specialityLabel: s.specialityLabel || s.specialitySlug || "",
    insuranceSector: s.insuranceSector,
    homeLat: home?.lat ?? null,
    homeLng: home?.lng ?? null,
  };
}
