import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import en from "@/lib/i18n/locales/en.json";
import { translate } from "@/lib/i18n/translate";

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return sources(path);
    return /\.tsx?$/.test(name) ? [path] : [];
  });
}

describe("i18n keys", () => {
  it("every literal t(\"…\") key used in the app exists", () => {
    const missing: string[] = [];
    for (const file of [...sources("app"), ...sources("components"), ...sources("lib")]) {
      const text = readFileSync(file, "utf8");
      for (const m of text.matchAll(/\bt\("([a-zA-Z0-9_.]+)"(, \{[^}]*count)?/g)) {
        const key = m[1];
        const value = m[2] ? translate(en, key, { count: 2 }) : translate(en, key);
        if (value === key) missing.push(`${file}: ${key}`);
      }
    }
    expect(missing).toEqual([]);
  });
});
