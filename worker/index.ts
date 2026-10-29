// The worker process: everything that runs in the background, apart from the web server,
// so that a slow job never blocks a page. Same image as the web app, started with
// `docker-entrypoint.sh worker`. Today: cleanup, the nightly backup and the appointment
// searches (every APPT_TICK_SECONDS); later phases add assistant turns.
import { setTimeout as sleep } from "node:timers/promises";
import { db, sqlite } from "../lib/db/client";
import { backupDatabase, hasBackupFor } from "../lib/maintenance/backup";
import { cleanup } from "../lib/maintenance/cleanup";
import { SearchRunner } from "../lib/appointments/runner";
import { migrationsApplied } from "../lib/maintenance/migrations";

const TICK_MS = Number(process.env.WORKER_TICK_SECONDS ?? 60) * 1000;
const BACKUP_DIR = process.env.BACKUP_DIR ?? "./data/backups";
const BACKUP_KEEP = Number(process.env.BACKUP_KEEP ?? 14);
/** Hour of day (server time) from which the daily backup is made. */
const BACKUP_HOUR = Number(process.env.BACKUP_HOUR ?? 3);
/** How often due appointment searches are picked up ("Run now" waits at most this long). */
const APPT_TICK_MS = Math.max(5, Number(process.env.APPT_TICK_SECONDS ?? 15)) * 1000;

let stopping = false;
const wake = new AbortController(); // ends the sleep between ticks on shutdown
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    console.log(`[worker] ${signal}, stopping`);
    stopping = true;
    wake.abort();
  });
}

async function waitForMigrations(): Promise<void> {
  while (!stopping && !migrationsApplied(sqlite, "./drizzle")) {
    console.log("[worker] waiting for the web process to apply migrations");
    await sleep(5000);
  }
}

async function tick(now: Date): Promise<void> {
  const removed = cleanup(db, now);
  if (removed.tokens + removed.invites + removed.rateLimits > 0) {
    console.log("[worker] cleanup", removed);
  }
  if (BACKUP_KEEP > 0 && now.getHours() >= BACKUP_HOUR && !hasBackupFor(BACKUP_DIR, now)) {
    const { file, removed: old } = await backupDatabase(sqlite, BACKUP_DIR, now, BACKUP_KEEP);
    console.log(`[worker] backup written to ${file}${old.length ? `, removed ${old.join(", ")}` : ""}`);
  }
}

async function main(): Promise<void> {
  await waitForMigrations();
  console.log(`[worker] started, tick every ${TICK_MS / 1000}s, backups in ${BACKUP_DIR} (keep ${BACKUP_KEEP})`);
  // Appointment searches run on their own, faster loop; runs are started, not awaited.
  const searches = new SearchRunner(db);
  searches.start(new Date());
  let lastTick = 0;
  while (!stopping) {
    const now = new Date();
    searches.tick(now);
    if (now.getTime() - lastTick >= TICK_MS) {
      lastTick = now.getTime();
      try {
        await tick(now);
      } catch (e) {
        console.error("[worker] tick failed:", e);
      }
    }
    await sleep(APPT_TICK_MS, undefined, { signal: wake.signal }).catch(() => undefined);
  }
  await searches.stop(5000);
  sqlite.close();
}

void main();
