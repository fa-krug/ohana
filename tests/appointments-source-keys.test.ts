import { describe, expect, it } from "vitest";
import { ignoreKey, dedupKey } from "@/lib/appointments/sources/keys";

describe("ignoreKey", () => {
  it("namespaces by source so identical slug+motive differ across sources", () => {
    expect(ignoreKey("doctolib", "dr-x", 1)).not.toBe(ignoreKey("jameda", "dr-x", 1));
  });
});

describe("dedupKey", () => {
  it("normalizes name + zip case/whitespace when coords are absent", () => {
    expect(dedupKey("  Dr. Anna Meyer ", "", "", "80331")).toBe(
      dedupKey("dr. anna meyer", "", "", "80331"),
    );
  });

  it("prefers coordinates and matches across geocoders within ~1km rounding", () => {
    // Same doctor, coords differing below the 2-decimal rounding → same identity,
    // even though one row also carries a zipcode and the other does not.
    const doctolib = dedupKey("Dr. Anna Meyer", "48.1372", "11.5755", "80331");
    const jameda = dedupKey("Dr. Anna Meyer", "48.1379", "11.5751", "");
    expect(jameda).toBe(doctolib);
  });

  it("returns empty when neither coords nor zipcode are available", () => {
    expect(dedupKey("Dr. Anna Meyer", "", "", "")).toBe("");
  });
});
