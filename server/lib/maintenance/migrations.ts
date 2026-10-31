import { readFileSync } from "node:fs";
import { join } from "node:path";
import type Database from "better-sqlite3";

/** Whether every migration in `folder` has been applied (the server process applies them). */
export function migrationsApplied(sqlite: Database.Database, folder: string): boolean {
  const journal = JSON.parse(readFileSync(join(folder, "meta/_journal.json"), "utf8")) as { entries: unknown[] };
  try {
    const row = sqlite.prepare("select count(*) as n from __drizzle_migrations").get() as { n: number };
    return row.n >= journal.entries.length;
  } catch {
    return false; // the table doesn't exist yet
  }
}
