import { describe, expect, it } from "vitest";
import { jamedaListingUrl, type JamedaTarget } from "@/lib/appointments/jameda/client";

const B = "https://www.jameda.de";

function leistung(label: string, loc: string): JamedaTarget {
  return { type: "leistung", slug: "psychotherapie", label, loc, citySlug: "" };
}
function specialization(slug: string, city: string): JamedaTarget {
  return { type: "specialization", slug, label: "ignored", loc: "ignored", citySlug: city };
}

describe("jamedaListingUrl (/suchen — leistung/erkrankung)", () => {
  it("builds a bare q + loc URL", () => {
    expect(jamedaListingUrl(B, leistung("Psychotherapie", "Berlin"), {}, 0)).toBe(
      "https://www.jameda.de/suchen?q=Psychotherapie&loc=Berlin",
    );
  });

  it("encodes spaces and parentheses in q", () => {
    expect(jamedaListingUrl(B, leistung("Psychotherapie (Erstgespräch)", "Planegg"), {}, 0)).toBe(
      "https://www.jameda.de/suchen?q=Psychotherapie+%28Erstgespr%C3%A4ch%29&loc=Planegg",
    );
  });

  it("appends the insurance_types filter", () => {
    expect(jamedaListingUrl(B, leistung("Psychotherapie", "Berlin"), { insuranceType: "government" }, 0)).toBe(
      "https://www.jameda.de/suchen?q=Psychotherapie&loc=Berlin&filters%5Binsurance_types%5D%5B%5D=government",
    );
  });

  it("appends both filters and page together", () => {
    expect(
      jamedaListingUrl(B, leistung("Psychotherapie", "Berlin"), { insuranceType: "private", kidsFriendly: true }, 1),
    ).toBe(
      "https://www.jameda.de/suchen?q=Psychotherapie&loc=Berlin&filters%5Binsurance_types%5D%5B%5D=private&filters%5Bkids_friendly%5D%5B%5D=true&page=2",
    );
  });

  it("erkrankung terms also use /suchen", () => {
    const target: JamedaTarget = { type: "erkrankung", slug: "depression", label: "Depression", loc: "Berlin", citySlug: "berlin" };
    expect(jamedaListingUrl(B, target, {}, 0)).toBe("https://www.jameda.de/suchen?q=Depression&loc=Berlin");
  });

  it("appends online_only only for video === 'only'", () => {
    expect(jamedaListingUrl(B, leistung("Psychiater", "Berlin"), { video: "only" }, 0)).toBe(
      "https://www.jameda.de/suchen?q=Psychiater&loc=Berlin&filters%5Bonline_only%5D%5B%5D=true",
    );
  });

  it("does not append online_only for video 'any' or 'exclude'", () => {
    expect(jamedaListingUrl(B, leistung("Psychiater", "Berlin"), { video: "any" }, 0)).toBe(
      "https://www.jameda.de/suchen?q=Psychiater&loc=Berlin",
    );
    expect(jamedaListingUrl(B, leistung("Psychiater", "Berlin"), { video: "exclude" }, 0)).toBe(
      "https://www.jameda.de/suchen?q=Psychiater&loc=Berlin",
    );
  });

  it("orders online_only after kids_friendly", () => {
    expect(
      jamedaListingUrl(
        B,
        leistung("Psychiater", "Berlin"),
        { insuranceType: "private", kidsFriendly: true, video: "only" },
        0,
      ),
    ).toBe(
      "https://www.jameda.de/suchen?q=Psychiater&loc=Berlin&filters%5Binsurance_types%5D%5B%5D=private&filters%5Bkids_friendly%5D%5B%5D=true&filters%5Bonline_only%5D%5B%5D=true",
    );
  });
});

describe("jamedaListingUrl (landing page — specialization)", () => {
  it("builds the /{slug}/{citySlug} landing URL", () => {
    expect(jamedaListingUrl(B, specialization("psychiater", "berlin"), {}, 0)).toBe(
      "https://www.jameda.de/psychiater/berlin",
    );
  });

  it("appends filters as a query string", () => {
    expect(
      jamedaListingUrl(B, specialization("psychiater", "muenchen"), { insuranceType: "private", kidsFriendly: true }, 0),
    ).toBe(
      "https://www.jameda.de/psychiater/muenchen?filters%5Binsurance_types%5D%5B%5D=private&filters%5Bkids_friendly%5D%5B%5D=true",
    );
  });

  it("appends 1-indexed page", () => {
    expect(jamedaListingUrl(B, specialization("psychiater", "berlin"), {}, 1)).toBe(
      "https://www.jameda.de/psychiater/berlin?page=2",
    );
  });

  it("falls back to /suchen when a specialization is missing its slug or citySlug", () => {
    const noSlug: JamedaTarget = { type: "specialization", slug: "", label: "Psychiater", loc: "Berlin", citySlug: "berlin" };
    expect(jamedaListingUrl(B, noSlug, {}, 0)).toBe("https://www.jameda.de/suchen?q=Psychiater&loc=Berlin");
  });

  it("appends online_only on the landing-page variant", () => {
    expect(jamedaListingUrl(B, specialization("psychiater", "berlin"), { video: "only" }, 0)).toBe(
      "https://www.jameda.de/psychiater/berlin?filters%5Bonline_only%5D%5B%5D=true",
    );
  });
});
