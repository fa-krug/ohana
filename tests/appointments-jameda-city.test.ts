import { describe, expect, it } from "vitest";
import { citySlug } from "@/lib/appointments/jameda/city";

describe("citySlug", () => {
  it("transliterates umlauts and slugifies", () => {
    expect(citySlug("München, Deutschland")).toBe("muenchen");
  });

  it("handles Köln", () => {
    expect(citySlug("Köln")).toBe("koeln");
  });

  it("handles Düsseldorf with country suffix", () => {
    expect(citySlug("Düsseldorf, Deutschland")).toBe("duesseldorf");
  });

  it("handles ß", () => {
    expect(citySlug("Straßberg")).toBe("strassberg");
  });

  it("returns empty string for empty input", () => {
    expect(citySlug("")).toBe("");
  });
});
