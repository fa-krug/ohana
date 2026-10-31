import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { parseDirectoryIndex, filterTerms, cleanLabel, type JamedaTerm } from "@/lib/appointments/jameda/terms";

const html = readFileSync("tests/fixtures/appointments/jameda_leistungen.html", "utf8");

describe("parseDirectoryIndex", () => {
  it("extracts typed {slug,label} pairs from a directory index", () => {
    const items = parseDirectoryIndex(html, "leistungen", "leistung");
    expect(items.length).toBeGreaterThan(0);
    const akupunktur = items.find((i) => i.slug === "akupunktur");
    expect(akupunktur?.label).toBe("Akupunktur");
    expect(akupunktur?.type).toBe("leistung");
  });

  it("preserves umlauts and punctuation in labels", () => {
    const items = parseDirectoryIndex(html, "leistungen", "leistung");
    const chiro = items.find((i) => i.slug === "chiropraktik-wirbelsaeulenbeschwerden");
    expect(chiro?.label).toBe("Chiropraktik / Wirbelsäulenbeschwerden");
  });

  it("ignores city links (a second path segment) and de-dupes", () => {
    const items = parseDirectoryIndex(html, "leistungen", "leistung");
    expect(items.filter((i) => i.slug === "akupunktur")).toHaveLength(1);
    expect(items.every((i) => !i.slug.includes("/"))).toBe(true);
  });

  it("skips A–Z alphabet-nav links (single-char slugs)", () => {
    const nav = [
      '<a href="https://www.jameda.de/leistungen/a">A</a>',
      '<a href="https://www.jameda.de/leistungen/akupunktur">Akupunktur</a>',
    ].join("\n");
    const items = parseDirectoryIndex(nav, "leistungen", "leistung");
    expect(items.map((i) => i.slug)).toEqual(["akupunktur"]);
  });

  it("decodes HTML entities in labels", () => {
    const anchor = '<a href="https://www.jameda.de/erkrankungen/x-y">A &amp; B</a>';
    const items = parseDirectoryIndex(anchor, "erkrankungen", "erkrankung");
    expect(items[0].label).toBe("A & B");
  });
});

describe("cleanLabel", () => {
  it("strips tags, decodes entities, and collapses whitespace", () => {
    expect(cleanLabel("  Foo  &amp;  <b>Bar</b> ")).toBe("Foo & Bar");
  });
});

describe("filterTerms", () => {
  const data: JamedaTerm[] = [
    { slug: "psychiater", label: "Psychiater", type: "specialization" },
    { slug: "psychotherapie", label: "Psychotherapie", type: "leistung" },
    { slug: "depression", label: "Depression", type: "erkrankung" },
    { slug: "akupunktur", label: "Akupunktur", type: "leistung" },
  ];

  it("returns [] for an empty query", () => {
    expect(filterTerms(data, "  ")).toEqual([]);
  });

  it("matches slug or label case-insensitively across types", () => {
    const hits = filterTerms(data, "psych");
    expect(hits.map((h) => h.slug).sort()).toEqual(["psychiater", "psychotherapie"]);
  });

  it("respects the limit", () => {
    expect(filterTerms(data, "a", 1)).toHaveLength(1);
  });
});
