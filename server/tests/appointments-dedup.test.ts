import { describe, expect, it } from "vitest";
import { dedupeResults } from "@/lib/appointments/sources/dedup";
import type { NormalizedResult } from "@/lib/appointments/sources/types";

function r(over: Partial<NormalizedResult>): NormalizedResult {
  return {
    source: "doctolib", doctorName: "Dr Anna Meyer", motiveLabel: "", practiceName: "",
    bookingUrl: "u", providerSlug: "s", motiveId: 0, slotDatetime: new Date("2026-07-10T10:00:00Z"),
    isNextSlot: false, doctorSubtitle: "", speciality: "", practiceAddress: "",
    practiceCity: "", practiceZipcode: "80331", practiceLatitude: "", practiceLongitude: "", ...over,
  };
}

describe("dedupeResults", () => {
  it("keeps the earliest slot when the same doctor appears on both sources", () => {
    const out = dedupeResults([
      r({ source: "doctolib", slotDatetime: new Date("2026-07-10T10:00:00Z") }),
      r({ source: "jameda", slotDatetime: new Date("2026-07-08T09:00:00Z") }),
    ]);
    expect(out).toHaveLength(1);
    expect(out[0].source).toBe("jameda");
  });

  it("does not merge different doctors or blank-zip rows", () => {
    const out = dedupeResults([
      r({ doctorName: "Dr A", practiceZipcode: "" , providerSlug: "a" }),
      r({ doctorName: "Dr B", practiceZipcode: "", providerSlug: "b" }),
    ]);
    expect(out).toHaveLength(2);
  });

  it("does not merge the SAME doctor across sources when NO locality is known", () => {
    // No coords and no zipcode on either row → no cross-source identity, so both survive.
    const out = dedupeResults([
      r({ doctorName: "Dr Anna Meyer", source: "doctolib", providerSlug: "am-dl", practiceZipcode: "" }),
      r({ doctorName: "Dr Anna Meyer", source: "jameda", providerSlug: "am-jm", practiceZipcode: "" }),
    ]);
    expect(out).toHaveLength(2);
  });

  it("merges the same doctor across sources by name + coordinates (jameda has no zip)", () => {
    const out = dedupeResults([
      r({
        source: "doctolib", providerSlug: "am-dl", practiceZipcode: "80331",
        practiceLatitude: "48.1372", practiceLongitude: "11.5755",
        slotDatetime: new Date("2026-07-10T10:00:00Z"),
      }),
      r({
        source: "jameda", providerSlug: "am-jm", practiceZipcode: "",
        practiceLatitude: "48.1379", practiceLongitude: "11.5751", // ~1km off, same 2-decimal cell
        slotDatetime: new Date("2026-07-08T09:00:00Z"),
      }),
    ]);
    expect(out).toHaveLength(1);
    expect(out[0].source).toBe("jameda"); // earlier slot wins
  });
});
