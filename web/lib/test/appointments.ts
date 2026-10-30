import { randomUUID } from "node:crypto";
import type { Db } from "@/lib/db";
import { apptResults, apptRuns, apptSearches } from "@/lib/db/schema";
import { NOW } from "./factories";

type SearchValues = typeof apptSearches.$inferInsert;
type RunValues = typeof apptRuns.$inferInsert;
type ResultValues = typeof apptResults.$inferInsert;

export function makeSearch(db: Db, familyId: string, over: Partial<SearchValues> = {}) {
  return db
    .insert(apptSearches)
    .values({ id: randomUUID(), familyId, name: "Derm", createdAt: NOW, updatedAt: NOW, ...over })
    .returning()
    .get();
}

export function makeRun(db: Db, searchId: string, over: Partial<RunValues> = {}) {
  return db
    .insert(apptRuns)
    .values({
      id: randomUUID(),
      searchId,
      startedAt: NOW,
      finishedAt: NOW,
      status: "OK",
      triggeredBy: "SCHEDULE",
      ...over,
    })
    .returning()
    .get();
}

export function makeResult(db: Db, runId: string, over: Partial<ResultValues> = {}) {
  return db
    .insert(apptResults)
    .values({
      runId,
      doctorName: "Dr A",
      bookingUrl: "https://www.doctolib.de/a",
      providerSlug: "dr-a",
      motiveId: 1,
      slotDatetime: new Date(NOW.getTime() + 2 * 24 * 60 * 60 * 1000),
      ...over,
    })
    .returning()
    .get();
}
