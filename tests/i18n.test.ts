import { describe, expect, it } from "vitest";
import { pickLocale } from "@/lib/i18n/locale";
import { translate, translateList } from "@/lib/i18n/translate";

const dict = {
  common: { save: "Save", hi: "Hi {{name}}" },
  items_one: "{{count}} item",
  items_other: "{{count}} items",
  days: ["Mon", "Tue"],
};

describe("pickLocale", () => {
  it("picks the first supported candidate", () => {
    expect(pickLocale([null, "de", "en"])).toBe("de");
  });
  it("falls back to base language then default", () => {
    expect(pickLocale(["de-DE"])).toBe("de");
    expect(pickLocale(["fr", "es"])).toBe("en");
  });
});

describe("translate", () => {
  it("resolves nested keys", () => expect(translate(dict, "common.save")).toBe("Save"));
  it("interpolates vars", () => expect(translate(dict, "common.hi", { name: "Al" })).toBe("Hi Al"));
  it("handles plurals via count", () => {
    expect(translate(dict, "items", { count: 1 })).toBe("1 item");
    expect(translate(dict, "items", { count: 3 })).toBe("3 items");
  });
  it("returns the key when missing", () => expect(translate(dict, "nope.here")).toBe("nope.here"));
  it("translateList returns arrays", () => expect(translateList(dict, "days")).toEqual(["Mon", "Tue"]));
});
