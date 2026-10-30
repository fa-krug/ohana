import type { Db } from "@/lib/db";
import type { apptSearches } from "@/lib/db/schema";

export type SourceId = "doctolib" | "jameda";
export type SearchRow = typeof apptSearches.$inferSelect;

export interface NormalizedResult {
  source: SourceId;
  doctorName: string;
  motiveLabel: string;
  practiceName: string;
  bookingUrl: string;
  providerSlug: string;
  motiveId: number; // 0 when the source has no motive concept
  slotDatetime: Date;
  isNextSlot: boolean;
  doctorSubtitle: string;
  speciality: string;
  practiceAddress: string;
  practiceCity: string;
  practiceZipcode: string;
  practiceLatitude: string;
  practiceLongitude: string;
}

export interface CollectOpts {
  dayLimit: number;
  maxPages: number;
  now: Date;
  /** Keys from ignoreKey() for this search across all sources. */
  ignored: Set<string>;
}

export interface CollectOutcome {
  results: NormalizedResult[];
  skipped: string[];
  doctorsFound: number;
  doctorsMatched: number;
}

export interface AppointmentSource {
  readonly id: SourceId;
  collectResults(db: Db, search: SearchRow, opts: CollectOpts): Promise<CollectOutcome>;
}
