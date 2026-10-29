import { describe, expect, it } from "vitest";
import { DoctolibClient } from "@/lib/appointments/doctolib/client";
import { acceptsSector } from "@/lib/appointments/pipeline";
import hcpSearch from "./fixtures/appointments/hcp_search.json";
import funnel from "./fixtures/appointments/slot_selection_funnel_info.json";
import availabilities from "./fixtures/appointments/availabilities.json";
import nextSlot from "./fixtures/appointments/availabilities_next_slot.json";
import specialitySuggest from "./fixtures/appointments/doctolib_speciality_suggest.json";

const client = new DoctolibClient("https://www.doctolib.de/search", 0);

describe("parseSearch", () => {
  it("extracts total and provider slugs from the full path", () => {
    const { total, providers } = client.parseSearch(hcpSearch as Record<string, unknown>);
    expect(total).toBe(43);
    expect(providers.length).toBe(2);
    expect(providers[0].slug).toBe("stephanie-gruener");
    expect(providers[0].path).toContain("/kinder-und-jugendlichenpsychotherapeut/");
  });
});

describe("parseBooking", () => {
  it("reads profile, motives and agendas", () => {
    const booking = client.parseBooking(funnel as Record<string, unknown>);
    expect(booking.profile.name).toBe("Frau Stephanie Grüner");
    expect(booking.motives.length).toBeGreaterThan(0);
    expect(booking.agendas[0].visit_motive_ids).toContain(booking.motives[0].id);
    expect(booking.agendas[0].insurance_sector_enabled).toBe(true);
    expect(booking.places[0].name).toContain("Kinder");
  });

  it("reads subtitle, speciality and place address/coords", () => {
    const booking = client.parseBooking(funnel as Record<string, unknown>);
    expect(booking.profile.subtitle).toContain("Kinder");
    expect(booking.profile.speciality).toContain("Kinder");
    expect(booking.places[0].address).toBe("Waldwiesenstraße 50");
    expect(booking.places[0].city).toBe("München");
    expect(booking.places[0].zipcode).toBe("81375");
    expect(booking.places[0].latitude).toBeCloseTo(48.1164982, 5);
    expect(booking.places[0].longitude).toBeCloseTo(11.4772101, 5);
  });
});

describe("parseSlots", () => {
  it("flattens per-day slots", () => {
    const { slots, nextSlot: n } = client.parseSlots(availabilities as Record<string, unknown>);
    expect(slots).toHaveLength(2);
    expect(n).toBeNull();
  });
  it("returns next_slot when no concrete slots", () => {
    const { slots, nextSlot: n } = client.parseSlots(nextSlot as Record<string, unknown>);
    expect(slots).toHaveLength(0);
    expect(n).toBe("2026-07-06T11:30:00.000+02:00");
  });
});

describe("parseSpecialitySuggestions", () => {
  it("keeps only SPECIALITY entries with a slug", () => {
    const out = client.parseSpecialitySuggestions(specialitySuggest as Record<string, unknown>);
    expect(out.length).toBeGreaterThan(0);
    expect(out[0]).toHaveProperty("slug");
    expect(out[0]).toHaveProperty("label");
  });
});

describe("acceptsSector", () => {
  const bookingWith = (flags: (boolean | null)[]) => ({
    profile: { id: 1, name: "x", subtitle: "", speciality: "" },
    motives: [],
    agendas: flags.map((f, i) => ({
      id: i,
      visit_motive_ids: [],
      practice_id: null,
      booking_disabled: false,
      insurance_sector_enabled: f,
    })),
    places: [],
  });

  it("keeps a provider when no sector is searched", () => {
    expect(acceptsSector(bookingWith([false]), undefined)).toBe(true);
  });
  it("drops a provider whose every bookable agenda is sector-disabled", () => {
    expect(acceptsSector(bookingWith([false, false]), "public")).toBe(false);
  });
  it("keeps a provider with at least one sector-enabled agenda", () => {
    expect(acceptsSector(bookingWith([false, true]), "public")).toBe(true);
  });
  it("keeps a provider when the flag is missing (null)", () => {
    expect(acceptsSector(bookingWith([null]), "public")).toBe(true);
  });
});
