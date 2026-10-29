import { describe, expect, it } from "vitest";
import { summarizeOutcomes } from "@/lib/appointments/sources/index";
import type { SourceOutcome } from "@/lib/appointments/sources/index";
import type { NormalizedResult } from "@/lib/appointments/sources/types";

function slot(over: Partial<NormalizedResult>): NormalizedResult {
  return {
    source: "doctolib", doctorName: "Dr Anna Meyer", motiveLabel: "", practiceName: "",
    bookingUrl: "u", providerSlug: "s", motiveId: 0, slotDatetime: new Date("2026-07-10T10:00:00Z"),
    isNextSlot: false, doctorSubtitle: "", speciality: "", practiceAddress: "",
    practiceCity: "", practiceZipcode: "80331", practiceLatitude: "", practiceLongitude: "", ...over,
  };
}

function outcome(over: Partial<SourceOutcome>): SourceOutcome {
  return { id: "doctolib", results: [], skipped: [], doctorsFound: 0, doctorsMatched: 0, ...over };
}

describe("summarizeOutcomes", () => {
  it("dedup: same doctor+zip on two sources keeps the earliest slot", () => {
    const outcomes: SourceOutcome[] = [
      outcome({
        id: "doctolib",
        results: [slot({ source: "doctolib", slotDatetime: new Date("2026-07-10T10:00:00Z") })],
        doctorsFound: 1, doctorsMatched: 1,
      }),
      outcome({
        id: "jameda",
        results: [slot({ source: "jameda", slotDatetime: new Date("2026-07-10T08:00:00Z") })],
        doctorsFound: 1, doctorsMatched: 1,
      }),
    ];
    const summary = summarizeOutcomes(outcomes);
    expect(summary.merged).toHaveLength(1);
    expect(summary.slotsFound).toBe(1);
    expect(summary.merged[0].source).toBe("jameda");
  });

  it("a fully-failed source → failed === true", () => {
    const outcomes: SourceOutcome[] = [
      outcome({ id: "doctolib", doctorsFound: 3, skipped: ["a", "b", "c"], results: [] }),
    ];
    const summary = summarizeOutcomes(outcomes);
    expect(summary.failed).toBe(true);
  });

  it("partial skip (2 of 3 providers succeeded, 1 errored) → NOT a failure", () => {
    const outcomes: SourceOutcome[] = [
      outcome({ id: "doctolib", doctorsFound: 3, skipped: ["a"], results: [] }),
    ];
    const summary = summarizeOutcomes(outcomes);
    expect(summary.failed).toBe(false);
    expect(summary.skipped).toHaveLength(1);
  });

  it("clean-but-empty (no doctors at all) → NOT a failure", () => {
    const outcomes: SourceOutcome[] = [
      outcome({ id: "doctolib", doctorsFound: 0, skipped: [], results: [] }),
    ];
    const summary = summarizeOutcomes(outcomes);
    expect(summary.failed).toBe(false);
  });

  it("one source clean, the OTHER fully failed → failed === true (not masked)", () => {
    const outcomes: SourceOutcome[] = [
      outcome({ id: "jameda", doctorsFound: 0, skipped: [], results: [] }),
      outcome({ id: "doctolib", doctorsFound: 2, skipped: ["x", "y"], results: [] }),
    ];
    const summary = summarizeOutcomes(outcomes);
    expect(summary.failed).toBe(true);
  });

  it("a source failing fails the run even when the other returned results", () => {
    const outcomes: SourceOutcome[] = [
      outcome({
        id: "doctolib",
        results: [slot({ source: "doctolib" })],
        doctorsFound: 1, doctorsMatched: 1,
      }),
      outcome({ id: "jameda", doctorsFound: 0, skipped: ["jameda: boom"], results: [] }),
    ];
    const summary = summarizeOutcomes(outcomes);
    expect(summary.failed).toBe(true);
  });
});
