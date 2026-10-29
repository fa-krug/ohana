import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { parsePgDump, pgBool, pgDate, pgDay, unescapeCopy } from "@/lib/import/pgdump";
import { FP_DUMP } from "@/lib/test/legacy";

describe("parsePgDump: COPY format (pg_dump's default)", () => {
  const tables = parsePgDump(readFileSync(FP_DUMP, "utf8"));

  it("reads the public tables with their columns", () => {
    expect(tables.get("families")).toHaveLength(2);
    expect(tables.get("families")![0]).toMatchObject({ id: "fpKrugFamily00000001", name: "Krug", legacy_id: "legacyKrug0000000001" });
    expect(tables.get("families")![1].legacy_id).toBeNull();
    expect(tables.get("entry_types")![0]).toMatchObject({ position: "0", year: "2026", role: "covers" });
  });

  it("keeps only the public schema (auth.users is not family-planner's users)", () => {
    expect(tables.get("users")!.map((u) => u.email)).toEqual(["anna@example.com", "admin", "ben@example.com"]);
  });

  it("undoes the escapes", () => {
    const notes = tables.get("day_notes")!;
    expect(notes[0].comment).toBe("Heiligabend\tbei Oma\nab 15 Uhr");
    expect(notes[0].icon).toBe("🎄");
    expect(notes[1].comment).toBe("Back\\slash");
    expect(unescapeCopy("\\N")).toBeNull();
    expect(unescapeCopy("a\\101\\x42")).toBe("aAB");
  });

  it("fails on a COPY block without its end", () => {
    expect(() => parsePgDump("COPY public.x (a) FROM stdin;\n1\n")).toThrow(/terminated/);
  });
});

describe("parsePgDump: INSERT format (--column-inserts)", () => {
  const dump = [
    "SET standard_conforming_strings = on;",
    "INSERT INTO public.users (id, email, name, password_hash, is_admin) VALUES ('u1', 'a@x.test', 'O''Brien; Jr.', NULL, true);",
    'INSERT INTO public.entry_types (family_id, id, "position", year) VALUES',
    "\t('f1', 'vacation', 0, 2026),",
    "\t('f1', 'multi', -1, 2025);",
    "INSERT INTO public.day_notes (family_id, day, comment) VALUES ('f1', '2026-01-01', 'line one",
    "INSERT INTO fake (x) VALUES (1);",
    "line three') ON CONFLICT DO NOTHING;",
    "INSERT INTO public.families (id, name, legacy_id) VALUES ('f1', E'Tab\\there', '{}'::text[]);",
    "INSERT INTO auth.users (id, email) VALUES ('x', 'y');",
  ].join("\n");
  const tables = parsePgDump(dump);

  it("reads values, NULL, booleans, numbers and doubled quotes", () => {
    expect(tables.get("users")).toEqual([
      { id: "u1", email: "a@x.test", name: "O'Brien; Jr.", password_hash: null, is_admin: "t" },
    ]);
    expect(tables.get("entry_types")!.map((r) => [r.id, r.position, r.year])).toEqual([
      ["vacation", "0", "2026"],
      ["multi", "-1", "2025"],
    ]);
  });

  it("keeps strings across lines, E'' escapes and skips casts and other schemas", () => {
    expect(tables.get("day_notes")![0].comment).toBe("line one\nINSERT INTO fake (x) VALUES (1);\nline three");
    expect(tables.has("fake")).toBe(false);
    expect(tables.get("families")![0]).toEqual({ id: "f1", name: "Tab\there", legacy_id: "{}" });
    expect(tables.get("users")).toHaveLength(1);
  });

  it("rejects INSERTs without column names", () => {
    expect(() => parsePgDump("INSERT INTO public.users VALUES ('u1', 'a@x.test');")).toThrow(/--column-inserts/);
  });
});

describe("value conversions", () => {
  it("parses Postgres timestamps and dates", () => {
    expect(pgDate("2024-05-01 10:00:00.123456+00")?.toISOString()).toBe("2024-05-01T10:00:00.123Z");
    expect(pgDate("2025-01-02 09:30:00+01")?.toISOString()).toBe("2025-01-02T08:30:00.000Z");
    expect(pgDate("2025-01-02 09:30:00+05:30")?.toISOString()).toBe("2025-01-02T04:00:00.000Z");
    expect(pgDate("2025-01-02")?.toISOString()).toBe("2025-01-02T00:00:00.000Z");
    expect(pgDate(null)).toBeNull();
    expect(pgDay("2026-07-01")).toBe("2026-07-01");
    expect(pgBool("t")).toBe(true);
    expect(pgBool("f")).toBe(false);
  });
});
