import { describe, expect, it } from "vitest";
import { googleSearchUrl } from "@/lib/appointments/google-search";

describe("googleSearchUrl", () => {
  it("joins non-empty parts and url-encodes the query", () => {
    const url = googleSearchUrl(["Frau Stephanie Grüner", "Kinderpsychotherapeutin", "Waldwiesenstraße 50 München"]);
    expect(url).toBe(
      "https://www.google.com/search?q=" +
        encodeURIComponent("Frau Stephanie Grüner Kinderpsychotherapeutin Waldwiesenstraße 50 München"),
    );
  });
  it("skips blank/null/undefined parts", () => {
    expect(googleSearchUrl(["Dr. X", "", null, undefined, "Berlin"])).toBe(
      "https://www.google.com/search?q=" + encodeURIComponent("Dr. X Berlin"),
    );
  });
});
