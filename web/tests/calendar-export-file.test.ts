import { describe, expect, it } from "vitest";
import { exportFileName, isExportFormat, parseExportFile } from "@/lib/calendar/export-file";

describe("export file (Settings → Data)", () => {
  it("names the download after the family and the day, without characters file systems refuse", () => {
    expect(exportFileName("Krug", "2026-10-29")).toBe("Krug 2026-10-29.json");
    expect(exportFileName('A/B\\C:D*E?F"G<H>I|J', "2026-01-02")).toBe("A-B-C-D-E-F-G-H-I-J 2026-01-02.json");
    expect(exportFileName("x//:y", "2026-01-02")).toBe("x-y 2026-01-02.json");
    expect(exportFileName("Line\nbreak", "2026-01-02")).toBe("Line-break 2026-01-02.json");
    expect(exportFileName("Müller & Söhne", "2026-01-02")).toBe("Müller & Söhne 2026-01-02.json");
    expect(exportFileName("  ", "2026-01-02")).toBe("family 2026-01-02.json");
  });

  it("knows the current and the old format", () => {
    expect(isExportFormat("family-planner")).toBe(true);
    expect(isExportFormat("vacation-planner")).toBe(true);
    expect(isExportFormat("cookless")).toBe(false);
    expect(isExportFormat(undefined)).toBe(false);
  });

  it("accepts only JSON objects with an export file's format", () => {
    const file = { format: "family-planner", version: 2, types: [], entries: {} };
    expect(parseExportFile(JSON.stringify(file))).toEqual(file);
    expect(parseExportFile(JSON.stringify({ ...file, format: "vacation-planner" }))).not.toBeNull();
    expect(parseExportFile(JSON.stringify({ ...file, format: "other" }))).toBeNull();
    expect(parseExportFile(JSON.stringify({ version: 2 }))).toBeNull();
    expect(parseExportFile("[]")).toBeNull();
    expect(parseExportFile("null")).toBeNull();
    expect(parseExportFile('"family-planner"')).toBeNull();
    expect(parseExportFile("not json")).toBeNull();
    expect(parseExportFile("")).toBeNull();
  });
});
