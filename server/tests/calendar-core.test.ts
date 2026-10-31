import { describe, expect, it } from "vitest";
import {
  applyNotes,
  changedNotesOnly,
  type EntryType,
  fillWith,
  gapDays,
  parseClipboardText,
  pasteTargets,
  patternOf,
  range,
  stats,
  toClipboardText,
  toggleType,
  toNoteOps,
  toOps,
  yearDays,
} from "@/lib/calendar/core";

describe("calendar core (family-planner app/src/lib/core.ts)", () => {
  const eq = (a: unknown, b: unknown) => expect(a).toEqual(b);

  const types: EntryType[] = [
    { id: "holiday", name: "Holiday", color: "#f59e0b", role: "day_off" },
    { id: "vac-a", name: "Vacation A", color: "#22c55e", role: "covers" },
    { id: "vac-b", name: "Vacation B", color: "#3b82f6", role: "covers" },
    { id: "daycare", name: "Day care closed", color: "#8b5cf6", role: "needs_cover" },
  ];

  it("year days", () => {
    eq(yearDays(2024).length, 366);
    eq(yearDays(2026).length, 365);
    eq(range("2026-03-02", "2026-02-27"), ["2026-02-27", "2026-02-28", "2026-03-01", "2026-03-02"]);
  });

  it("toggle adds to all, or removes when all have it", () => {
    const entries = new Map([["2026-08-03", ["vac-a"]]]);
    const days = ["2026-08-03", "2026-08-04"];
    const added = toggleType(entries, days, "vac-a");
    eq(
      [...added],
      [
        ["2026-08-03", ["vac-a"]],
        ["2026-08-04", ["vac-a"]],
      ],
    );
    const both = new Map(added);
    eq([...toggleType(both, days, "vac-a").values()], [[], []]);
    // A second type is added next to the existing one.
    eq(toggleType(entries, ["2026-08-03"], "daycare").get("2026-08-03"), ["vac-a", "daycare"]);
  });

  it("gaps: needs cover on weekdays without covers/day off", () => {
    const entries = new Map([
      ["2026-08-03", ["daycare"]], // Mon – gap
      ["2026-08-04", ["daycare", "vac-a"]], // covered
      ["2026-08-05", ["daycare", "holiday"]], // holiday covers
      ["2026-08-08", ["daycare"]], // Saturday – ignored
    ]);
    eq(gapDays(entries, types, 2026), ["2026-08-03"]);
  });

  it("stats count workdays without weekends and holidays", () => {
    const entries = new Map([
      ["2026-08-07", ["vac-a"]], // Fri
      ["2026-08-08", ["vac-a"]], // Sat
      ["2026-08-10", ["vac-a", "holiday"]], // Mon, holiday
      ["2026-08-11", ["vac-a", "vac-b"]],
    ]);
    const s = stats(entries, types, 2026);
    eq(s.get("vac-a"), { days: 4, workdays: 2 });
    eq(s.get("vac-b"), { days: 1, workdays: 1 });
    eq(s.get("holiday"), { days: 1, workdays: 1 });
  });

  it("paste: single day gets the whole pattern, bigger selections repeat it", () => {
    eq(pasteTargets(["2026-12-30"], 5, "2026-12-31", false), ["2026-12-30", "2026-12-31"]);
    eq(pasteTargets(["2026-08-07"], 2, "2026-12-31", true), ["2026-08-07", "2026-08-10"]);
    const sel = ["2026-01-05", "2026-01-06", "2026-01-07"];
    eq(pasteTargets(sel, 1, "2026-12-31", false), sel);
    eq([...fillWith(sel, [["vac-a"], []]).values()], [["vac-a"], [], ["vac-a"]]);
  });

  it("ops are grouped add/remove per type", () => {
    const entries = new Map([
      ["2026-01-05", ["vac-a"]],
      ["2026-01-06", ["vac-a"]],
    ]);
    const next = new Map([
      ["2026-01-05", ["vac-b"]],
      ["2026-01-06", ["vac-a", "vac-b"]],
    ]);
    eq(toOps(entries, next), [
      { action: "remove", type: "vac-a", dates: ["2026-01-05"] },
      { action: "add", type: "vac-b", dates: ["2026-01-05", "2026-01-06"] },
    ]);
  });

  it("clipboard text round trip and spreadsheet columns", () => {
    const days = ["2026-01-05", "2026-01-06"];
    const entries = new Map([["2026-01-05", ["vac-a", "daycare"]]]);
    const pattern = patternOf(entries, days);
    const text = toClipboardText(days, pattern, types);
    eq(text, "2026-01-05\tVacation A, Day care closed\n2026-01-06\t");
    eq(parseClipboardText(text, types).pattern, pattern);

    const parsed = parseClipboardText("vacation b\nHoliday; Vacation A\nfoo\n", types);
    eq(parsed.pattern, [["vac-b"], ["holiday", "vac-a"], []]);
    eq(parsed.unknown, ["foo"]);
  });

  it("notes: only changed days, empty notes count as removal", () => {
    const xmas = { icon: "🎄", comment: "Christmas" };
    const notes = new Map([
      ["2026-12-25", xmas],
      ["2026-12-26", { icon: "🎁", comment: "" }],
    ]);
    const next = new Map([
      ["2026-12-25", { icon: "🎄", comment: "Christmas" }], // unchanged
      ["2026-12-26", { icon: "", comment: "" }], // removed
      ["2026-12-27", null], // had no note – unchanged
      ["2026-12-31", { icon: "🎆", comment: "" }], // new
    ]);
    const changes = changedNotesOnly(notes, next);
    eq(
      [...changes],
      [
        ["2026-12-26", null],
        ["2026-12-31", { icon: "🎆", comment: "" }],
      ],
    );
    applyNotes(notes, changes);
    eq(
      [...notes],
      [
        ["2026-12-25", xmas],
        ["2026-12-31", { icon: "🎆", comment: "" }],
      ],
    );
  });

  it("note ops: identical notes are grouped, removals cleared at once", () => {
    const easter = { icon: "🐣", comment: "Easter" };
    const next = new Map([
      ["2026-04-06", easter],
      ["2026-01-01", null],
      ["2026-04-05", { ...easter }],
      ["2026-04-03", { icon: "🐣", comment: "Good Friday" }],
      ["2025-12-31", { icon: "", comment: "" }],
    ]);
    eq(toNoteOps(next), [
      { action: "clear", dates: ["2025-12-31", "2026-01-01"] },
      { action: "set", dates: ["2026-04-05", "2026-04-06"], icon: "🐣", comment: "Easter" },
      { action: "set", dates: ["2026-04-03"], icon: "🐣", comment: "Good Friday" },
    ]);
    eq(toNoteOps(new Map()), []);
  });
});
