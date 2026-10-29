// Search pipeline — port of findmyappointment's runPipeline (itself a port of the Django
// SearchPipeline).
//
// Never throws once the run exists: records an ERROR status/message on the run instead, so
// the worker is never crashed by a scrape failure. A single bad provider is caught,
// recorded and skipped; a source that fails entirely (or whose every provider fails)
// fails the run.

import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { apptIgnored, apptResults, apptRuns, apptSearches } from "@/lib/db/schema";
import type { DoctolibClient } from "./doctolib/client";
import { DoctolibSource } from "./sources/doctolib";
import { ignoreKey } from "./sources/keys";
import { sourcesFor, summarizeOutcomes } from "./sources/index";
import type { AppointmentSource, NormalizedResult, SourceId } from "./sources/types";

export { acceptsSector, hasSlotWithin } from "./sources/doctolib";

export type TriggeredBy = "SCHEDULE" | "MANUAL";

// Rows per INSERT. Each result binds ~17 columns; 500 rows ≈ 8.5k params, well under
// SQLite's ~32k bound-variable limit, so large result sets store instead of throwing.
const INSERT_CHUNK = 500;

/** Inserts results in chunks so a large result set never exceeds SQLite's limit. */
export function storeResults(db: Db, runId: string, results: NormalizedResult[]): void {
  for (let i = 0; i < results.length; i += INSERT_CHUNK) {
    const batch = results.slice(i, i + INSERT_CHUNK);
    db.insert(apptResults)
      .values(batch.map((r) => ({ runId, ...r })))
      .run();
  }
}

export interface PipelineOpts {
  triggeredBy?: TriggeredBy;
  /** Test injection: a Doctolib client for the Doctolib source. */
  client?: DoctolibClient;
  /** Test injection: replaces the search's sources altogether. */
  sources?: AppointmentSource[];
  now?: () => Date;
}

/** Runs the pipeline for a search; returns the created run id. */
export async function runPipeline(db: Db, searchId: string, opts: PipelineOpts = {}): Promise<string> {
  const now = opts.now ?? (() => new Date());
  const search = db.select().from(apptSearches).where(eq(apptSearches.id, searchId)).get();
  if (!search) throw new Error("search not found");

  const runId = randomUUID();
  db.insert(apptRuns)
    .values({ id: runId, searchId, startedAt: now(), status: "RUNNING", triggeredBy: opts.triggeredBy ?? "SCHEDULE" })
    .run();

  let status = "NO_AVAILABILITY";
  let errorMessage = "";
  let doctorsFound = 0;
  let doctorsMatched = 0;
  let slotsFound = 0;

  try {
    const srcs =
      opts.sources ??
      sourcesFor(search).map((s) => (s.id === "doctolib" && opts.client ? new DoctolibSource(opts.client) : s));

    const ignored = new Set(
      db
        .select({ source: apptIgnored.source, slug: apptIgnored.providerSlug, motiveId: apptIgnored.motiveId })
        .from(apptIgnored)
        .where(eq(apptIgnored.searchId, search.id))
        .all()
        .map((e) => ignoreKey(e.source as SourceId, e.slug, e.motiveId)),
    );
    const collectOpts = { dayLimit: search.dayLimit, maxPages: search.maxPages, now: now(), ignored };

    const outcomes = await Promise.all(
      srcs.map(async (s) => {
        try {
          return { id: s.id, ...(await s.collectResults(db, search, collectOpts)) };
        } catch (exc) {
          return {
            id: s.id,
            results: [],
            skipped: [`${s.id}: ${(exc as Error).name}: ${(exc as Error).message}`],
            doctorsFound: 0,
            doctorsMatched: 0,
          };
        }
      }),
    );

    const summary = summarizeOutcomes(outcomes);
    doctorsFound = summary.doctorsFound;
    doctorsMatched = summary.doctorsMatched;
    slotsFound = summary.slotsFound;

    // Any source failure fails the whole run (ERROR) rather than being masked as a skip.
    if (summary.failed) throw new Error(summary.skipped.join("\n"));
    errorMessage = summary.skipped.length ? `Skipped: ${summary.skipped.join("\n")}` : "";
    storeResults(db, runId, summary.merged);
    status = slotsFound > 0 ? "OK" : "NO_AVAILABILITY";
  } catch (exc) {
    status = "ERROR";
    errorMessage = `${(exc as Error).name}: ${(exc as Error).message}`;
  }

  const finishedAt = now();
  db.update(apptRuns)
    .set({ finishedAt, status, errorMessage, doctorsFound, doctorsMatched, slotsFound })
    .where(eq(apptRuns.id, runId))
    .run();
  db.update(apptSearches)
    .set({ lastRunAt: finishedAt, lastStatus: status })
    .where(eq(apptSearches.id, search.id))
    .run();
  return runId;
}
