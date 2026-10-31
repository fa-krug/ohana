import { describe, expect, it } from "vitest";
import { citySlug, JamedaSource, type JamedaApi } from "@/lib/appointments/sources/jameda";
import { ignoreKey } from "@/lib/appointments/sources/keys";
import type { CollectOpts, SearchRow } from "@/lib/appointments/sources/types";

// ---------------------------------------------------------------------------
// citySlug helper
// ---------------------------------------------------------------------------

describe("citySlug", () => {
  it("transliterates umlauts and slugifies", () => {
    expect(citySlug("München, Deutschland")).toBe("muenchen");
  });

  it("returns empty string for empty input", () => {
    expect(citySlug("")).toBe("");
  });

  it("handles Düsseldorf", () => {
    expect(citySlug("Düsseldorf, Deutschland")).toBe("duesseldorf");
  });

  it("handles plain city without country suffix", () => {
    expect(citySlug("Berlin")).toBe("berlin");
  });
});

// ---------------------------------------------------------------------------
// Helpers / fixtures
// ---------------------------------------------------------------------------

const NOW = new Date("2025-06-01T10:00:00Z");
const DAY_LIMIT = 30;
const CUTOFF = new Date(NOW.getTime() + DAY_LIMIT * 24 * 60 * 60 * 1000);

// Slots in-window (within cutoff)
const IN_WINDOW_SLOT = "2025-06-15T09:00:00Z";
// Slot just beyond cutoff
const OUT_OF_WINDOW_SLOT = new Date(CUTOFF.getTime() + 24 * 60 * 60 * 1000).toISOString();

const DOCTOR_A = {
  doctorId: "doc-1",
  addressId: "addr-1",
  slug: "dr-smith",
  name: "Dr. Smith",
  bookingUrl: "https://www.jameda.de/dr-smith/",
  speciality: "Allgemeinmedizin",
  city: "Berlin",
  latitude: "52.5200",
  longitude: "13.4050",
  hasSlots: true,
  isOnlineOnly: false,
};

const DOCTOR_B = {
  doctorId: "doc-2",
  addressId: "addr-2",
  slug: "dr-jones",
  name: "Dr. Jones",
  bookingUrl: "https://www.jameda.de/dr-jones/",
  speciality: "Allgemeinmedizin",
  city: "Berlin",
  latitude: "52.5300",
  longitude: "13.4150",
  hasSlots: true,
  isOnlineOnly: false,
};

// Doctor with no in-window slots but a near next-slot
const DOCTOR_C = {
  doctorId: "doc-3",
  addressId: "addr-3",
  slug: "dr-near",
  name: "Dr. Near",
  bookingUrl: "https://www.jameda.de/dr-near/",
  speciality: "Allgemeinmedizin",
  city: "Berlin",
  latitude: "52.5100",
  longitude: "13.3950",
  hasSlots: true,
  isOnlineOnly: false,
};

const NEXT_SLOT_FOR_C = "2025-06-20T14:00:00Z";

function makeSearch(overrides: Partial<SearchRow> = {}): SearchRow {
  return {
    id: "search-1",
    name: "Test search",
    sources: "jameda",
    jamedaSpecialitySlug: "allgemeinmedizin",
    locationLabel: "Berlin, Deutschland",
    dayLimit: DAY_LIMIT,
    maxPages: 1,
    notifyEnabled: false,
    notifyOnlyEarlier: false,
    earliestSeen: null,
    createdAt: NOW,
    updatedAt: NOW,
    // Doctolib-specific fields (not used by JamedaSource)
    specialitySlug: "",
    specialityLabel: "",
    locationSlug: "",
    latitude: "",
    longitude: "",
    insuranceSector: "",
    familyId: "family-1",
    ...overrides,
  } as unknown as SearchRow;
}

function makeOpts(overrides: Partial<CollectOpts> = {}): CollectOpts {
  return {
    dayLimit: DAY_LIMIT,
    maxPages: 1,
    now: NOW,
    ignored: new Set<string>(),
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Fake JamedaApi
// ---------------------------------------------------------------------------

function makeFakeClient(
  doctors: typeof DOCTOR_A[],
  slotsMap: Record<string, string[]>,  // addressId → slot isos
  nextSlotMap: Record<string, string[]> = {},
): JamedaApi {
  return {
    async bootstrap() {},
    async searchListing(_target: unknown, _filters: unknown, _page: number): Promise<string> {
      return "";
    },
    parseListing(_html: string) {
      return doctors;
    },
    async fetchSlots(addressId: string, _start: string, _end: string) {
      const items = (slotsMap[addressId] ?? []).map((s) => ({ start: s, booked: false, link: "" }));
      return { _items: items };
    },
    async fetchNextSlot(addressId: string) {
      const items = (nextSlotMap[addressId] ?? []).map((s) => ({ start: s, booked: false, link: "" }));
      return { slots: items };
    },
    parseSlots(payload: Record<string, unknown>) {
      const raw =
        (payload._items as Record<string, unknown>[] | undefined) ??
        (payload.slots as Record<string, unknown>[] | undefined) ??
        [];
      const slots = (raw as { start: string; booked: boolean }[])
        .filter((e) => e.booked === false)
        .map((e) => e.start);
      return { slots, nextSlot: null };
    },
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("JamedaSource", () => {
  const DOCTOR_VIDEO = { ...DOCTOR_A, doctorId: "doc-v", addressId: "addr-v", name: "Dr. Video", isOnlineOnly: true };

  it("drops video-only doctors when jamedaVideo is 'exclude'", async () => {
    const fake = makeFakeClient(
      [DOCTOR_A, DOCTOR_VIDEO],
      { [DOCTOR_A.addressId]: [IN_WINDOW_SLOT], [DOCTOR_VIDEO.addressId]: [IN_WINDOW_SLOT] },
    );
    const source = new JamedaSource(fake);
    const outcome = await source.collectResults(null as never, makeSearch({ jamedaVideo: "exclude" }), makeOpts());
    expect(outcome.doctorsFound).toBe(1);
    expect(outcome.results.map((r) => r.providerSlug)).toEqual([DOCTOR_A.addressId]);
  });

  it("keeps video-only doctors when jamedaVideo is 'any'", async () => {
    const fake = makeFakeClient(
      [DOCTOR_A, DOCTOR_VIDEO],
      { [DOCTOR_A.addressId]: [IN_WINDOW_SLOT], [DOCTOR_VIDEO.addressId]: [IN_WINDOW_SLOT] },
    );
    const source = new JamedaSource(fake);
    const outcome = await source.collectResults(null as never, makeSearch({ jamedaVideo: "any" }), makeOpts());
    expect(outcome.doctorsFound).toBe(2);
  });

  it("returns empty outcome when jamedaSpecialitySlug is blank", async () => {
    const source = new JamedaSource();
    const search = makeSearch({ jamedaSpecialitySlug: "" });
    const outcome = await source.collectResults(null as never, search, makeOpts());
    expect(outcome.results).toHaveLength(0);
    expect(outcome.doctorsFound).toBe(0);
  });

  it("returns empty outcome when city cannot be derived (empty locationLabel)", async () => {
    const source = new JamedaSource();
    const search = makeSearch({ locationLabel: "" });
    const outcome = await source.collectResults(null as never, search, makeOpts());
    expect(outcome.results).toHaveLength(0);
  });

  it("returns only in-window slot for doctor A, excludes out-of-window", async () => {
    const fake = makeFakeClient(
      [DOCTOR_A],
      { [DOCTOR_A.addressId]: [IN_WINDOW_SLOT, OUT_OF_WINDOW_SLOT] },
    );
    const source = new JamedaSource(fake);
    const outcome = await source.collectResults(null as never, makeSearch(), makeOpts());
    expect(outcome.results).toHaveLength(1);
    const r = outcome.results[0];
    expect(r.source).toBe("jameda");
    expect(r.providerSlug).toBe(DOCTOR_A.addressId);
    expect(r.motiveId).toBe(0);
    expect(r.isNextSlot).toBe(false);
    expect(r.slotDatetime).toEqual(new Date(IN_WINDOW_SLOT));
    // Carried-through fields
    expect(r.bookingUrl).toBe(DOCTOR_A.bookingUrl);
    expect(r.practiceCity).toBe(DOCTOR_A.city);
    expect(r.practiceLatitude).toBe(DOCTOR_A.latitude);
    expect(r.practiceLongitude).toBe(DOCTOR_A.longitude);
    expect(r.speciality).toBe(DOCTOR_A.speciality);
  });

  it("excludes an ignored doctor", async () => {
    const fake = makeFakeClient(
      [DOCTOR_A, DOCTOR_B],
      {
        [DOCTOR_A.addressId]: [IN_WINDOW_SLOT],
        [DOCTOR_B.addressId]: [IN_WINDOW_SLOT],
      },
    );
    const ignored = new Set([ignoreKey("jameda", DOCTOR_B.addressId, 0)]);
    const source = new JamedaSource(fake);
    const outcome = await source.collectResults(null as never, makeSearch(), makeOpts({ ignored }));
    // Only doctor A should appear
    expect(outcome.results.every((r) => r.providerSlug !== DOCTOR_B.addressId)).toBe(true);
    expect(outcome.results.some((r) => r.providerSlug === DOCTOR_A.addressId)).toBe(true);
  });

  it("uses isNextSlot=true for doctor with no in-window slots but a nearest slot within cutoff", async () => {
    const fake = makeFakeClient(
      [DOCTOR_C],
      { [DOCTOR_C.addressId]: [OUT_OF_WINDOW_SLOT] },   // fetchSlots returns only out-of-window
      { [DOCTOR_C.addressId]: [NEXT_SLOT_FOR_C] },       // fetchNextSlot returns one within cutoff
    );
    const source = new JamedaSource(fake);
    const outcome = await source.collectResults(null as never, makeSearch(), makeOpts());
    expect(outcome.results).toHaveLength(1);
    expect(outcome.results[0].isNextSlot).toBe(true);
    expect(outcome.results[0].slotDatetime).toEqual(new Date(NEXT_SLOT_FOR_C));
    expect(outcome.results[0].providerSlug).toBe(DOCTOR_C.addressId);
  });

  it("skips doctor without hasSlots=true", async () => {
    const noSlotDoctor = { ...DOCTOR_A, hasSlots: false };
    const fake = makeFakeClient(
      [noSlotDoctor],
      { [noSlotDoctor.addressId]: [IN_WINDOW_SLOT] },
    );
    const source = new JamedaSource(fake);
    const outcome = await source.collectResults(null as never, makeSearch(), makeOpts());
    expect(outcome.results).toHaveLength(0);
  });

  it("deduplicates doctors with the same addressId across pages", async () => {
    // maxPages=2, but parseListing always returns the same doctor — should deduplicate
    const fake: JamedaApi = {
      ...makeFakeClient([DOCTOR_A], { [DOCTOR_A.addressId]: [IN_WINDOW_SLOT] }),
      parseListing: (_html: string) => [DOCTOR_A],
    };
    const source = new JamedaSource(fake);
    const outcome = await source.collectResults(null as never, makeSearch(), makeOpts({ maxPages: 2 }));
    // Second page returns same doctor → treated as "no fresh" → loop breaks
    // doctorsFound should be 1 (de-duped)
    expect(outcome.doctorsFound).toBe(1);
  });
});
