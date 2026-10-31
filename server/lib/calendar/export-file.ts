// The family's export file (GET /families/{id}/export, read back by POST …/import): its marks,
// and the checks the Settings → Data tab does before uploading one. Browser-safe.

/** Marks the JSON of GET /families/{id}/export, which POST /families/{id}/import reads back. */
export const EXPORT_FORMAT = "family-planner";
/** Files exported before family-planner's rename; same content. */
export const OLD_EXPORT_FORMAT = "vacation-planner";
/** 2 adds the finances; files of version 1 only have the calendar. */
export const EXPORT_VERSION = 2;

/** True for the `format` of an export file (the current one or the old name). */
export function isExportFormat(format: unknown): boolean {
  return format === EXPORT_FORMAT || format === OLD_EXPORT_FORMAT;
}

/** Parses a picked file's text; null unless it is JSON with an export file's `format`. The
 *  server checks the rest (version, types, entries, finances). */
export function parseExportFile(text: string): Record<string, unknown> | null {
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    return null;
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) return null;
  const file = data as Record<string, unknown>;
  return isExportFormat(file.format) ? file : null;
}

/** The download's name: "<family name> <YYYY-MM-DD>.json", without characters file systems
 *  refuse. */
export function exportFileName(familyName: string, today: string): string {
  const name = familyName.replace(/[\\/:*?"<>|\u0000-\u001f]+/g, "-").trim() || "family";
  return `${name} ${today}.json`;
}
