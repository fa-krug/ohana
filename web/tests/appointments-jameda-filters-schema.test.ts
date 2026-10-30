import { describe, expect, it } from "vitest";
import { searchInputSchema, JAMEDA_INSURANCE_TYPES, JAMEDA_VIDEO_MODES } from "@/lib/appointments/schema";

const base = {
  name: "Test",
  sources: "jameda",
  jamedaSpecialitySlug: "psychotherapie",
  jamedaSpecialityLabel: "Psychotherapie",
  latitude: "48.1",
  longitude: "11.4",
  locationLabel: "Planegg",
};

describe("searchInputSchema jameda filters", () => {
  it("defaults insurance type to '' and kids-friendly to false", () => {
    const v = searchInputSchema.parse(base);
    expect(v.jamedaInsuranceType).toBe("");
    expect(v.jamedaKidsFriendly).toBe(false);
  });

  it("accepts every valid insurance type", () => {
    for (const t of JAMEDA_INSURANCE_TYPES) {
      expect(searchInputSchema.parse({ ...base, jamedaInsuranceType: t }).jamedaInsuranceType).toBe(t);
    }
  });

  it("rejects an unknown insurance type", () => {
    expect(() => searchInputSchema.parse({ ...base, jamedaInsuranceType: "bogus" })).toThrow();
  });

  it("coerces kids-friendly boolean", () => {
    expect(searchInputSchema.parse({ ...base, jamedaKidsFriendly: true }).jamedaKidsFriendly).toBe(true);
  });

  it("defaults jamedaVideo to 'any'", () => {
    expect(searchInputSchema.parse(base).jamedaVideo).toBe("any");
  });

  it("accepts every valid jamedaVideo mode", () => {
    for (const m of JAMEDA_VIDEO_MODES) {
      expect(searchInputSchema.parse({ ...base, jamedaVideo: m }).jamedaVideo).toBe(m);
    }
  });

  it("rejects an unknown jamedaVideo mode", () => {
    expect(() => searchInputSchema.parse({ ...base, jamedaVideo: "bogus" })).toThrow();
  });
});
