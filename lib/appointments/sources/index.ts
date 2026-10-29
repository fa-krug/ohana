import { dedupeResults } from "./dedup";
import { DoctolibSource } from "./doctolib";
import { JamedaSource } from "./jameda";
import type { AppointmentSource, CollectOutcome, NormalizedResult, SearchRow, SourceId } from "./types";

export function sourcesFor(search: SearchRow): AppointmentSource[] {
  const out: AppointmentSource[] = [];
  if (search.sources === "doctolib" || search.sources === "both") out.push(new DoctolibSource());
  if (search.sources === "jameda" || search.sources === "both") out.push(new JamedaSource());
  return out.length ? out : [new DoctolibSource()];
}

export type SourceOutcome = CollectOutcome & { id: SourceId };

export interface RunSummary {
  merged: NormalizedResult[];
  doctorsFound: number;
  doctorsMatched: number;
  slotsFound: number;
  skipped: string[];
  /** True when ANY source failed → the whole run is marked ERROR. */
  failed: boolean;
}

export function summarizeOutcomes(outcomes: SourceOutcome[]): RunSummary {
  const merged = dedupeResults(outcomes.flatMap((o) => o.results));
  const skipped = outcomes.flatMap((o) => o.skipped);
  // A source "fails" if it threw entirely (no doctors, but errors) or every provider it
  // found failed. A partial per-provider skip (some providers failed, others succeeded) is
  // NOT a source failure, nor is a clean-but-empty result. If ANY source fails, the entire
  // run fails — a failed source is never masked by another source succeeding.
  const sourceFailed = (o: SourceOutcome) =>
    o.doctorsFound > 0 ? o.skipped.length === o.doctorsFound : o.skipped.length > 0;
  return {
    merged,
    doctorsFound: outcomes.reduce((n, o) => n + o.doctorsFound, 0),
    doctorsMatched: outcomes.reduce((n, o) => n + o.doctorsMatched, 0),
    slotsFound: merged.length,
    skipped,
    failed: outcomes.some(sourceFailed),
  };
}
