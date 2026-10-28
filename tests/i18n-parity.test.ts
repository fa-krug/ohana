import { describe, expect, it } from "vitest";
import en from "@/lib/i18n/locales/en.json";
import de from "@/lib/i18n/locales/de.json";

function keys(obj: unknown, prefix = ""): string[] {
  if (obj && typeof obj === "object" && !Array.isArray(obj)) {
    return Object.entries(obj as Record<string, unknown>).flatMap(([k, v]) =>
      keys(v, prefix ? `${prefix}.${k}` : k),
    );
  }
  return [prefix];
}

describe("i18n dictionaries", () => {
  it("en and de have identical key sets", () => {
    const enKeys = keys(en).sort();
    const deKeys = keys(de).sort();
    expect(deKeys).toEqual(enKeys);
  });
});
