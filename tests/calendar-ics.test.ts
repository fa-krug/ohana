import { describe, expect, it } from "vitest";
import { buildIcs, escapeText, foldLine } from "@/lib/calendar/ics";

const assert = (v: unknown) => expect(v).toBeTruthy();
const assertEquals = (a: unknown, b: unknown) => expect(a).toEqual(b);

describe("iCalendar feed (family-planner _shared/ics.ts)", () => {
  it("escapes text values", () => {
    assertEquals(escapeText("a,b;c\\d\ne"), "a\\,b\\;c\\\\d\\ne");
  });

  it("folds long lines at 75 octets", () => {
    const folded = foldLine("SUMMARY:" + "ä".repeat(60));
    for (const line of folded.split("\r\n")) {
      assert(new TextEncoder().encode(line).length <= 75);
    }
    assertEquals(folded.replace(/\r\n /g, ""), "SUMMARY:" + "ä".repeat(60));
  });

  it("merges consecutive days, also across months", () => {
    const ics = buildIcs({
      calendarName: "Test",
      uidPrefix: "r",
      types: [
        {
          family_id: "s",
          year: 2026,
          id: "v",
          name: "Vacation",
          color: "#000000",
          role: "covers" as const,
          position: 0,
        },
      ],
      entries: new Map([
        ["2026-01-30", ["v"]],
        ["2026-01-31", ["v"]],
        ["2026-02-01", ["v"]],
        ["2026-02-05", ["v"]],
      ]),
      now: new Date("2026-10-11T12:00:00Z"),
    });
    assertEquals(ics.match(/BEGIN:VEVENT/g)!.length, 2);
    assert(ics.includes("DTSTART;VALUE=DATE:20260130\r\nDTEND;VALUE=DATE:20260202"));
    assert(ics.includes("DTSTAMP:20261011T120000Z"));
    assert(ics.includes("UID:r-v-2026-01-30@vacation-planner"));
    assert(ics.endsWith("END:VCALENDAR\r\n"));
  });

  it("localizes gap summaries and descriptions in German", () => {
    const type = (id: string, name: string, role: "covers" | "needs_cover") => ({
      family_id: "s",
      year: 2026,
      id,
      name,
      color: "#000000",
      role,
      position: 0,
    });
    const input = {
      calendarName: "Test",
      uidPrefix: "r",
      types: [type("k", "Kita zu", "needs_cover"), type("v", "Urlaub", "covers")],
      entries: new Map([
        // Mon + Tue not covered, then Sat + Sun vacation (0 workdays).
        ["2026-08-03", ["k"]],
        ["2026-08-04", ["k"]],
        ["2026-08-08", ["v"]],
        ["2026-08-09", ["v"]],
      ]),
      gaps: true,
      now: new Date("2026-10-11T12:00:00Z"),
    };
    const de = buildIcs({ ...input, lang: "de" });
    assert(de.includes("SUMMARY:⚠ Nicht abgedeckt: Kita zu\r\n"));
    assert(de.includes("DESCRIPTION:⚠ Nicht abgedeckt: Kita zu: 2 Tage (2 Arbeitstage)"));
    assert(de.includes("DESCRIPTION:Urlaub: 2 Tage (0 Arbeitstage)\r\n"));

    const en = buildIcs(input);
    assert(en.includes("SUMMARY:⚠ Not covered: Kita zu\r\n"));
    assert(en.includes("DESCRIPTION:Urlaub: 2 days (0 workdays)\r\n"));
    assertEquals(buildIcs({ ...input, lang: "en" }), en);
  });

  it("turns day notes into events, merging identical consecutive notes", () => {
    const xmas = { icon: "🎄", comment: "Christmas" };
    const ics = buildIcs({
      calendarName: "Test",
      uidPrefix: "r",
      types: [],
      entries: new Map(),
      notes: new Map([
        ["2026-12-26", xmas],
        ["2026-12-24", xmas],
        ["2026-12-25", { ...xmas }],
        // Same comment, different icon: a separate event.
        ["2026-12-27", { icon: "🎁", comment: "Christmas" }],
        ["2026-12-31", { icon: "", comment: "Party\nBring snacks, drinks" }],
        ["2027-01-01", { icon: "🎆", comment: "" }],
      ]),
      now: new Date("2026-10-11T12:00:00Z"),
    });
    assertEquals(ics.match(/BEGIN:VEVENT/g)!.length, 4);
    assert(
      ics.includes(
        "UID:r-note-2026-12-24@vacation-planner\r\nDTSTAMP:20261011T120000Z\r\n" +
          "DTSTART;VALUE=DATE:20261224\r\nDTEND;VALUE=DATE:20261227\r\n" +
          "SUMMARY:🎄 Christmas\r\nDESCRIPTION:Christmas: 3 days (2 workdays)\r\n",
      ),
    );
    assert(ics.includes("UID:r-note-2026-12-27@vacation-planner"));
    // Only the first comment line goes into the summary; the description has all of it.
    assert(ics.includes("SUMMARY:Party\r\nDESCRIPTION:Party\\nBring snacks\\, drinks\r\n"));
    // Icon-only notes use the icon as summary and description.
    assert(ics.includes("SUMMARY:🎆\r\nDESCRIPTION:🎆\r\n"));
    // Events are ordered by date.
    const uids = [...ics.matchAll(/UID:r-note-(\S+)@/g)].map((m) => m[1]);
    assertEquals(uids, ["2026-12-24", "2026-12-27", "2026-12-31", "2027-01-01"]);
  });

  it("leaves the feed unchanged without notes", () => {
    const input = {
      calendarName: "Test",
      uidPrefix: "r",
      types: [],
      entries: new Map(),
      now: new Date("2026-10-11T12:00:00Z"),
    };
    assertEquals(buildIcs({ ...input, notes: new Map() }), buildIcs(input));
    assert(!buildIcs(input).includes("BEGIN:VEVENT"));
  });
});
