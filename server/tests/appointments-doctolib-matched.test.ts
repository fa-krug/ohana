import { describe, expect, it } from "vitest";
import { createTestDb } from "@/lib/test/db";
import type { Booking, DoctolibClient, Provider } from "@/lib/appointments/doctolib/client";
import { processProvider } from "@/lib/appointments/sources/doctolib";
import { ignoreKey } from "@/lib/appointments/sources/keys";

const freshDb = createTestDb;

const now = new Date("2026-07-05T09:00:00Z");
const start = now.toISOString();
const cutoff = new Date("2026-07-19T09:00:00Z"); // now + 14 days

function bookingWithOneMotive(): Booking {
  return {
    profile: { id: 1, name: "Dr A", subtitle: "", speciality: "" },
    motives: [{ id: 1, name: "Sprechstunde" }],
    agendas: [
      {
        id: 10,
        visit_motive_ids: [1],
        practice_id: 100,
        booking_disabled: false,
        insurance_sector_enabled: true,
      },
    ],
    places: [],
  };
}

/** Fake client whose availability call returns whatever `slots`/`nextSlot` are given. */
function fakeClient(booking: Booking, slots: string[], nextSlot: string | null): DoctolibClient {
  return {
    baseUrl: "https://www.doctolib.de/search",
    fetchProfile: async () => ({}),
    parseBooking: () => booking,
    fetchAvailabilities: async () => ({}),
    parseSlots: () => ({ slots, nextSlot }),
  } as unknown as DoctolibClient;
}

const provider: Provider = {
  slug: "dr-a",
  path: "/dr-a",
  name: "Dr A",
  matchedVisitMotiveId: 1,
  matchedAgendaIds: [10],
};

describe("processProvider matched semantics", () => {
  it("counts a doctor with a valid motive as matched even with no upcoming slot", async () => {
    const db = freshDb();
    const client = fakeClient(bookingWithOneMotive(), [], null); // gate: no availability
    const outcome = await processProvider(db, client, provider, new Set(), undefined, start, cutoff, now);
    expect(outcome.matched).toBe(true);
    expect(outcome.results).toEqual([]);
  });

  it("does not count a doctor whose only motive is ignored", async () => {
    const db = freshDb();
    const client = fakeClient(bookingWithOneMotive(), [], null);
    const ignored = new Set([ignoreKey("doctolib", "dr-a", 1)]);
    const outcome = await processProvider(db, client, provider, ignored, undefined, start, cutoff, now);
    expect(outcome.matched).toBe(false);
  });

  it("records slots for a matched doctor that does have upcoming availability", async () => {
    const db = freshDb();
    const client = fakeClient(bookingWithOneMotive(), ["2026-07-10T09:00:00Z"], null);
    const outcome = await processProvider(db, client, provider, new Set(), undefined, start, cutoff, now);
    expect(outcome.matched).toBe(true);
    expect(outcome.results).toHaveLength(1);
  });
});
