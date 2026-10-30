// Searches: create / update / delete, ignore list, "run now". Port of findmyappointment's
// lib/searches/manage.ts, scoped to a family: every function checks the actor's role
// (editors change, viewers only read) and that the search belongs to the family.

import { randomUUID } from "node:crypto";
import { and, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { apptIgnored, apptResults, apptRuns, apptSearchChannels, apptSearches } from "@/lib/db/schema";
import { type Actor, requireRole } from "@/lib/families/roles";
import { getChannelRow } from "@/lib/notifications/channels";
import type { SearchInput } from "./schema";
import { computeNextRunAt } from "./scheduling";

export type SearchRow = typeof apptSearches.$inferSelect;

/** The search, if it belongs to the family; else a 404. */
export function assertSearch(db: Db, familyId: string, searchId: string): SearchRow {
  const s = db.select().from(apptSearches).where(eq(apptSearches.id, searchId)).get();
  if (!s || s.familyId !== familyId) throw new AuthError(404, "Search not found.");
  return s;
}

function setChannels(db: Db, familyId: string, searchId: string, channelIds: string[]): void {
  const ids = [...new Set(channelIds)];
  for (const id of ids) getChannelRow(db, familyId, id);
  db.delete(apptSearchChannels).where(eq(apptSearchChannels.searchId, searchId)).run();
  for (const channelId of ids) db.insert(apptSearchChannels).values({ searchId, channelId }).run();
}

const searchColumns = (input: SearchInput) => ({
  name: input.name,
  sources: input.sources,
  specialitySlug: input.specialitySlug,
  specialityLabel: input.specialityLabel,
  jamedaSpecialitySlug: input.jamedaSpecialitySlug,
  jamedaSpecialityLabel: input.jamedaSpecialityLabel,
  jamedaSpecialityType: input.jamedaSpecialityType,
  jamedaInsuranceType: input.jamedaInsuranceType,
  jamedaKidsFriendly: input.jamedaKidsFriendly,
  jamedaVideo: input.jamedaVideo,
  latitude: input.latitude,
  longitude: input.longitude,
  locationLabel: input.locationLabel,
  insuranceSector: input.insuranceSector,
  dayLimit: input.dayLimit,
  maxPages: input.maxPages,
  enabled: input.enabled,
  scheduleType: input.scheduleType,
  scheduleMinutes: input.scheduleMinutes,
  cron: input.cron,
  notifyOnlyEarlier: input.notifyOnlyEarlier,
});

export function createSearch(db: Db, actor: Actor, familyId: string, input: SearchInput, now: Date): { id: string } {
  requireRole(db, actor, familyId, "editor");
  const id = randomUUID();
  const cols = searchColumns(input);
  db.transaction((tx) => {
    tx.insert(apptSearches)
      .values({
        id,
        familyId,
        ...cols,
        nextRunAt: cols.enabled ? computeNextRunAt(cols, now) : null,
        createdAt: now,
        updatedAt: now,
      })
      .run();
    setChannels(tx as unknown as Db, familyId, id, input.channelIds);
  });
  return { id };
}

export function updateSearch(db: Db, actor: Actor, familyId: string, searchId: string, input: SearchInput, now: Date): void {
  requireRole(db, actor, familyId, "editor");
  const existing = assertSearch(db, familyId, searchId);
  const cols = searchColumns(input);
  // (Re)schedule when enabling or when the cadence changes; leave a running schedule alone.
  const reschedule =
    cols.enabled &&
    (!existing.enabled ||
      existing.scheduleType !== cols.scheduleType ||
      existing.scheduleMinutes !== cols.scheduleMinutes ||
      existing.cron !== cols.cron);
  db.transaction((tx) => {
    tx.update(apptSearches)
      .set({
        ...cols,
        nextRunAt: !cols.enabled ? null : reschedule ? computeNextRunAt(cols, now) : existing.nextRunAt,
        updatedAt: now,
      })
      .where(eq(apptSearches.id, searchId))
      .run();
    setChannels(tx as unknown as Db, familyId, searchId, input.channelIds);
  });
}

export function deleteSearch(db: Db, actor: Actor, familyId: string, searchId: string): void {
  requireRole(db, actor, familyId, "editor");
  assertSearch(db, familyId, searchId);
  db.delete(apptSearches).where(eq(apptSearches.id, searchId)).run();
}

/** "Run now": the worker picks the search up within its next tick (never in the request). */
export function requestRun(db: Db, actor: Actor, familyId: string, searchId: string, now: Date): void {
  requireRole(db, actor, familyId, "editor");
  assertSearch(db, familyId, searchId);
  db.update(apptSearches).set({ runRequestedAt: now }).where(eq(apptSearches.id, searchId)).run();
}

/** Ignores a result's (source, provider, motive) for its search from now on. */
export function ignoreResult(db: Db, actor: Actor, familyId: string, resultId: number, now: Date): { searchId: string } {
  requireRole(db, actor, familyId, "editor");
  const result = db.select().from(apptResults).where(eq(apptResults.id, resultId)).get();
  if (!result) throw new AuthError(404, "Result not found.");
  const run = db.select().from(apptRuns).where(eq(apptRuns.id, result.runId)).get();
  if (!run) throw new AuthError(404, "Result not found.");
  const search = assertSearch(db, familyId, run.searchId);
  if (!result.providerSlug || result.motiveId === null) return { searchId: search.id };
  const exists = db
    .select({ id: apptIgnored.id })
    .from(apptIgnored)
    .where(
      and(
        eq(apptIgnored.searchId, search.id),
        eq(apptIgnored.source, result.source),
        eq(apptIgnored.providerSlug, result.providerSlug),
        eq(apptIgnored.motiveId, result.motiveId),
      ),
    )
    .get();
  if (!exists) {
    db.insert(apptIgnored)
      .values({
        searchId: search.id,
        source: result.source,
        providerSlug: result.providerSlug,
        motiveId: result.motiveId,
        doctorName: result.doctorName,
        motiveLabel: result.motiveLabel,
        createdAt: now,
      })
      .run();
  }
  return { searchId: search.id };
}

export function unignoreEntry(db: Db, actor: Actor, familyId: string, entryId: number): void {
  requireRole(db, actor, familyId, "editor");
  const entry = db.select().from(apptIgnored).where(eq(apptIgnored.id, entryId)).get();
  if (!entry) throw new AuthError(404, "Entry not found.");
  assertSearch(db, familyId, entry.searchId);
  db.delete(apptIgnored).where(eq(apptIgnored.id, entryId)).run();
}

export function channelIdsForSearch(db: Db, searchId: string): string[] {
  return db
    .select({ channelId: apptSearchChannels.channelId })
    .from(apptSearchChannels)
    .where(eq(apptSearchChannels.searchId, searchId))
    .all()
    .map((r) => r.channelId);
}

/** A stored search as the input that saves it again (the assistant's undo of a change). */
export function searchInputOf(db: Db, s: SearchRow): SearchInput {
  return {
    name: s.name,
    sources: s.sources as SearchInput["sources"],
    specialitySlug: s.specialitySlug,
    specialityLabel: s.specialityLabel,
    jamedaSpecialitySlug: s.jamedaSpecialitySlug,
    jamedaSpecialityLabel: s.jamedaSpecialityLabel,
    jamedaSpecialityType: s.jamedaSpecialityType as SearchInput["jamedaSpecialityType"],
    jamedaInsuranceType: s.jamedaInsuranceType as SearchInput["jamedaInsuranceType"],
    jamedaKidsFriendly: s.jamedaKidsFriendly,
    jamedaVideo: s.jamedaVideo as SearchInput["jamedaVideo"],
    latitude: s.latitude,
    longitude: s.longitude,
    locationLabel: s.locationLabel,
    insuranceSector: s.insuranceSector as SearchInput["insuranceSector"],
    dayLimit: s.dayLimit,
    maxPages: s.maxPages,
    enabled: s.enabled,
    scheduleType: s.scheduleType as SearchInput["scheduleType"],
    scheduleMinutes: s.scheduleMinutes,
    cron: s.cron,
    notifyOnlyEarlier: s.notifyOnlyEarlier,
    channelIds: channelIdsForSearch(db, s.id),
  };
}
