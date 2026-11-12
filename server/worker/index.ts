// The worker process: everything that runs in the background, apart from the HTTP server,
// so that a slow job never blocks a request. Same image as the server, started with
// `docker-entrypoint.sh worker`. Today: cleanup, the nightly backup and the appointment
// searches (every APPT_TICK_SECONDS), the daily notifications (coverage), chores that are due, the week ahead
// (geocoding event locations daily, the weekly digest), the assistant's chat turns, the
// recipe imports the share extension handed over, the holiday imports, the bank syncs of
// linked finance accounts and the knowledge base's documents waiting to be chunked, for their
// card or for the family's AI to read a page scan (all looked for every ASSISTANT_TICK_MS, a cheap indexed query; holidays are asked for
// once a day too).
import { setTimeout as sleep } from "node:timers/promises";
import { db, sqlite } from "../lib/db/client";
import { backupDatabase, hasBackupFor } from "../lib/maintenance/backup";
import { cleanup } from "../lib/maintenance/cleanup";
import { SearchRunner } from "../lib/appointments/runner";
import { ChatRunner } from "../lib/assistant/runner";
import { ImportRunner } from "../lib/meals/ai/import-queue";
import { defaultHolidaysEnv, HolidayRunner, requestDailyHolidaySyncs } from "../lib/calendar/holidays/sync";
import { BankSyncRunner } from "../lib/finance/bank/runner";
import { KnowledgeRunner } from "../lib/knowledge/runner";
import { KnowledgeCardRunner } from "../lib/knowledge/card-runner";
import { KnowledgeScanRunner } from "../lib/knowledge/scan-runner";
import { defaultAiEnv } from "../lib/assistant/routes";
import { migrationsApplied } from "../lib/maintenance/migrations";
import { dailyNotifications } from "../lib/notifications/daily";
import { weeklyDigests } from "../lib/digest/digest";
import { choreNotifications } from "../lib/chores/notify";
import { enabledModules, moduleEnabled } from "../lib/server-info";

const TICK_MS = Number(process.env.WORKER_TICK_SECONDS ?? 60) * 1000;
const BACKUP_DIR = process.env.BACKUP_DIR ?? "./data/backups";
const BACKUP_KEEP = Number(process.env.BACKUP_KEEP ?? 14);
/** Hour of day (server time) from which the daily backup is made. */
const BACKUP_HOUR = Number(process.env.BACKUP_HOUR ?? 3);
/** How often due appointment searches are picked up ("Run now" waits at most this long). */
const APPT_TICK_MS = Math.max(5, Number(process.env.APPT_TICK_SECONDS ?? 15)) * 1000;
/** How often chats that wait for a turn are looked for (a message waits at most this long). */
const ASSISTANT_TICK_MS = Math.max(200, Number(process.env.ASSISTANT_TICK_MS ?? 1000));

let stopping = false;
/** The holiday imports; off without HOLIDAYS_URL. */
const holidays = (() => {
  const env = defaultHolidaysEnv();
  return { enabled: env.source !== null, runner: new HolidayRunner(db, env) };
})();
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
    console.log("[worker] waiting for the server to apply migrations");
    await sleep(5000);
  }
}

async function tick(now: Date): Promise<void> {
  const removed = cleanup(db, now);
  if (Object.values(removed).some((n) => n > 0)) {
    console.log("[worker] cleanup", removed);
  }
  if (BACKUP_KEEP > 0 && now.getHours() >= BACKUP_HOUR && !hasBackupFor(BACKUP_DIR, now)) {
    const { file, removed: old } = await backupDatabase(sqlite, BACKUP_DIR, now, BACKUP_KEEP);
    console.log(`[worker] backup written to ${file}${old.length ? `, removed ${old.join(", ")}` : ""}`);
  }
  // Uncovered days in the next two weeks (phase 7).
  await dailyNotifications(db, now);
  // Chores that are due now, to their subscribers' devices (off with the module).
  if (moduleEnabled("chores")) await choreNotifications(db, now);
  // The week ahead (phase 11): places geocoded daily, the digest on DIGEST_WEEKDAY from DIGEST_HOUR.
  await weeklyDigests(db, now);
  // Public and school holidays (HOLIDAYS_URL): every family that imports them, once a day.
  if (holidays.enabled) requestDailyHolidaySyncs(db, now);
}

async function main(): Promise<void> {
  await waitForMigrations();
  console.log(`[worker] started, tick every ${TICK_MS / 1000}s, backups in ${BACKUP_DIR} (keep ${BACKUP_KEEP})`);
  console.log(`[worker] modules: ${enabledModules().join(", ")}`);
  // Modules turned off (DISABLED_MODULES) have no background work.
  const runSearches = moduleEnabled("appointments");
  const runChats = moduleEnabled("assistant");
  // Appointment searches run on their own, faster loop; runs are started, not awaited.
  const searches = new SearchRunner(db);
  if (runSearches) searches.start(new Date());
  // Assistant turns: claimed through the database, run without awaiting.
  const aiEnv = defaultAiEnv(db);
  const chats = new ChatRunner(aiEnv);
  // Recipe imports in the background (meals + assistant), started like the turns.
  const runImports = moduleEnabled("meals") && moduleEnabled("assistant");
  const imports = new ImportRunner(db);
  // Bank syncs (finance): started like the turns, never run twice.
  const runBankSyncs = moduleEnabled("finance");
  const bankSyncs = new BankSyncRunner(db);
  // The knowledge base's uploaded documents, chunked for the search (phase 12).
  const runKnowledge = moduleEnabled("knowledge");
  const knowledge = new KnowledgeRunner(db);
  // Their cards, with the family's AI (only where it is set up; off with the assistant).
  const cards = new KnowledgeCardRunner(aiEnv);
  // Page scans the app sent, read by the family's AI (likewise).
  const scans = new KnowledgeScanRunner(aiEnv);
  let lastTick = 0;
  let lastSearches = 0;
  while (!stopping) {
    const now = new Date();
    if (runChats) chats.tick(now);
    if (runImports) imports.tick(now);
    holidays.runner.tick(now);
    if (runBankSyncs) bankSyncs.tick(now);
    if (runKnowledge) knowledge.tick(now);
    if (runKnowledge && runChats) cards.tick(now);
    if (runKnowledge && runChats) scans.tick(now);
    if (runSearches && now.getTime() - lastSearches >= APPT_TICK_MS) {
      lastSearches = now.getTime();
      searches.tick(now);
    }
    if (now.getTime() - lastTick >= TICK_MS) {
      lastTick = now.getTime();
      try {
        await tick(now);
      } catch (e) {
        console.error("[worker] tick failed:", e);
      }
    }
    await sleep(ASSISTANT_TICK_MS, undefined, { signal: wake.signal }).catch(() => undefined);
  }
  await Promise.all([
    searches.stop(5000), chats.stop(5000), imports.stop(5000), holidays.runner.stop(5000), bankSyncs.stop(5000),
    knowledge.stop(5000), cards.stop(5000), scans.stop(5000),
  ]);
  sqlite.close();
}

void main();
