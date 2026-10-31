import { mkdirSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import type Database from "better-sqlite3";

const NAME = /^ohana-(\d{4}-\d{2}-\d{2})\.db$/;

export function backupName(now: Date): string {
  return `ohana-${now.toISOString().slice(0, 10)}.db`;
}

/** Whether today's backup exists already. */
export function hasBackupFor(dir: string, now: Date): boolean {
  try {
    return readdirSync(dir).includes(backupName(now));
  } catch {
    return false;
  }
}

/**
 * Writes a consistent copy of the live database (SQLite's online backup, safe while the
 * app writes) to `dir`/ohana-YYYY-MM-DD.db and keeps the newest `keep` copies. An off-site
 * job on the host copies this folder elsewhere (see README).
 */
export async function backupDatabase(
  sqlite: Database.Database,
  dir: string,
  now: Date,
  keep: number,
): Promise<{ file: string; removed: string[] }> {
  mkdirSync(dir, { recursive: true });
  const file = join(dir, backupName(now));
  await sqlite.backup(file);
  const backups = readdirSync(dir)
    .filter((f) => NAME.test(f))
    .sort()
    .reverse();
  const removed = backups.slice(Math.max(keep, 1));
  for (const f of removed) rmSync(join(dir, f), { force: true });
  return { file, removed };
}
