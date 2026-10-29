// Reading the SQLite files of cookless and findmyappointment (both Drizzle apps: timestamps
// are integer seconds, booleans 0/1).
import Database from "better-sqlite3";

export type Row = Record<string, unknown>;

/** Opens a source database read-only. */
export function openSourceDb(path: string, label: string): Database.Database {
  try {
    const db = new Database(path, { readonly: true, fileMustExist: true });
    db.pragma("schema_version"); // reads the header: fails on a file that isn't SQLite
    return db;
  } catch (e) {
    throw new Error(`${label}: can't open ${path}: ${e instanceof Error ? e.message : String(e)}`);
  }
}

export function hasTable(db: Database.Database, table: string): boolean {
  return db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(table) !== undefined;
}

/** Throws when the database lacks a table or column the import reads: an older version of
 *  the app (start its latest version once, so it migrates) or not that app's database. */
export function requireSchema(db: Database.Database, label: string, schema: Record<string, string[]>): void {
  for (const [table, columns] of Object.entries(schema)) {
    if (!hasTable(db, table)) {
      throw new Error(`${label}: the database has no table "${table}" (is it ${label}'s database, of its latest version?)`);
    }
    const have = new Set((db.prepare(`PRAGMA table_info("${table}")`).all() as Array<{ name: string }>).map((c) => c.name));
    const missing = columns.filter((c) => !have.has(c));
    if (missing.length > 0) {
      throw new Error(
        `${label}: table "${table}" lacks ${missing.join(", ")}; start the latest version of ${label} once so it migrates, then copy the file again`,
      );
    }
  }
}

export function all(db: Database.Database, sql: string): Row[] {
  return db.prepare(sql).all() as Row[];
}

export function str(v: unknown, fallback = ""): string {
  return v === null || v === undefined ? fallback : String(v);
}

export function strOrNull(v: unknown): string | null {
  return v === null || v === undefined ? null : String(v);
}

export function int(v: unknown, fallback = 0): number {
  const n = Number(v);
  return v === null || v === undefined || v === "" || !Number.isFinite(n) ? fallback : Math.trunc(n);
}

export function intOrNull(v: unknown): number | null {
  return v === null || v === undefined || v === "" ? null : int(v);
}

export function bool(v: unknown): boolean {
  return v === 1 || v === true || v === "1" || v === "true";
}

/** A Drizzle `mode: "timestamp"` column (seconds). */
export function sec(v: unknown): Date | null {
  if (v === null || v === undefined || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? new Date(n * 1000) : null;
}

/** A coordinate stored as text; null when blank or not a number. */
export function coord(v: unknown): number | null {
  const s = str(v).trim();
  if (!s) return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}
