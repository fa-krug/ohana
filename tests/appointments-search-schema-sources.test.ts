import { describe, expect, it } from "vitest";
import { searchInputSchema } from "@/lib/appointments/schema";

const base = { name: "S", latitude: "48.1", longitude: "11.5", channelIds: [] };

describe("searchInputSchema sources", () => {
  it("requires a doctolib speciality when sources includes doctolib", () => {
    const r = searchInputSchema.safeParse({ ...base, sources: "doctolib", specialitySlug: "" });
    expect(r.success).toBe(false);
  });
  it("requires a jameda speciality when sources is jameda", () => {
    const r = searchInputSchema.safeParse({ ...base, sources: "jameda", specialitySlug: "", jamedaSpecialitySlug: "" });
    expect(r.success).toBe(false);
  });
  it("accepts 'both' with both slugs set", () => {
    const r = searchInputSchema.safeParse({ ...base, sources: "both", specialitySlug: "x", jamedaSpecialitySlug: "y" });
    expect(r.success).toBe(true);
  });
});
