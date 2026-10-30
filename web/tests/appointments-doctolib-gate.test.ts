import { describe, expect, it } from "vitest";
import { DoctolibClient } from "@/lib/appointments/doctolib/client";
import { hasSlotWithin } from "@/lib/appointments/pipeline";
import hcpSearch from "./fixtures/appointments/hcp_search.json";

const client = new DoctolibClient("https://www.doctolib.de/search", 0);

describe("parseSearch matched-motive extraction", () => {
  it("reads the matched visit motive id and agenda ids per provider", () => {
    const { providers } = client.parseSearch(hcpSearch as Record<string, unknown>);
    expect(providers[0].matchedVisitMotiveId).toBe(10840027);
    expect(providers[0].matchedAgendaIds).toEqual([1697590]);
    expect(providers[1].matchedVisitMotiveId).toBe(15252821);
    expect(providers[1].matchedAgendaIds).toEqual([2431123]);
  });
});

describe("hasSlotWithin (gate decision)", () => {
  const cutoff = new Date("2026-07-10T00:00:00Z");

  it("is true when a concrete slot falls on/before the cutoff", () => {
    expect(hasSlotWithin(["2026-07-05T09:00:00Z"], null, cutoff)).toBe(true);
  });

  it("is true when only next_slot falls within the cutoff", () => {
    expect(hasSlotWithin([], "2026-07-08T09:00:00Z", cutoff)).toBe(true);
  });

  it("is false when everything is beyond the cutoff", () => {
    expect(hasSlotWithin(["2026-08-01T09:00:00Z"], "2026-09-01T09:00:00Z", cutoff)).toBe(false);
  });

  it("is false when there is nothing at all", () => {
    expect(hasSlotWithin([], null, cutoff)).toBe(false);
  });

  it("ignores unparseable datetimes", () => {
    expect(hasSlotWithin(["not-a-date"], null, cutoff)).toBe(false);
  });
});
