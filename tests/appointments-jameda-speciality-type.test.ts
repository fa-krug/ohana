import { describe, expect, it } from "vitest";
import { searchInputSchema, JAMEDA_TERM_TYPES } from "@/lib/appointments/schema";

const base = {
  name: "T", sources: "jameda" as const,
  jamedaSpecialitySlug: "psychiater",
  latitude: "52.5", longitude: "13.4",
};

describe("searchInputSchema jamedaSpecialityType", () => {
  it("defaults to leistung when omitted", () => {
    const v = searchInputSchema.parse(base);
    expect(v.jamedaSpecialityType).toBe("leistung");
  });

  it("accepts each valid term type", () => {
    for (const t of JAMEDA_TERM_TYPES) {
      expect(searchInputSchema.parse({ ...base, jamedaSpecialityType: t }).jamedaSpecialityType).toBe(t);
    }
  });

  it("rejects an unknown term type", () => {
    expect(() => searchInputSchema.parse({ ...base, jamedaSpecialityType: "bogus" })).toThrow();
  });
});
