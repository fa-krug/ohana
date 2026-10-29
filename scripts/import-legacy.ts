// One-time import of the old apps into an empty, migrated Ohana database (DATABASE_FILE):
//
//   npm run import-legacy -- [--family-planner dump.sql] [--cookless cookless.db]
//     [--cookless-media ./media] [--fma findmyappointment.db] [--map import-map.json]
//     [--dry-run] [--force] [--report report.json]
//
// (in the container: docker compose run --rm web ./node_modules/.bin/tsx scripts/import-legacy.ts …)
// Every source is optional. --dry-run does the whole import in a transaction and rolls it
// back, printing what it would do. See README → "Importing the old apps".
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { openCookless } from "../lib/import/cookless/accounts";
import { loadFamilyPlannerDump } from "../lib/import/family-planner/source";
import { openFma } from "../lib/import/fma/accounts";
import type { ImportMap, ImportSources } from "../lib/import/types";

const USAGE = `Usage: npm run import-legacy -- [--family-planner <dump.sql>] [--cookless <cookless.db>]
  [--cookless-media <media dir>] [--fma <findmyappointment.db>] [--map <import-map.json>]
  [--dry-run] [--force] [--report <report.json>]`;

function fail(message: string): never {
  console.error(message);
  process.exit(1);
}

function parseArgs(argv: string[]) {
  const valued = new Set(["--family-planner", "--cookless", "--cookless-media", "--fma", "--map", "--report"]);
  const flags = new Set(["--dry-run", "--force"]);
  const out: Record<string, string | boolean> = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--help" || a === "-h") {
      console.log(USAGE);
      process.exit(0);
    }
    if (flags.has(a)) out[a] = true;
    else if (valued.has(a)) {
      const v = argv[++i];
      if (!v || v.startsWith("--")) fail(`${a} needs a value\n${USAGE}`);
      out[a] = v;
    } else fail(`Unknown argument ${a}\n${USAGE}`);
  }
  return out;
}

function existing(path: string, what: string): string {
  const abs = resolve(path);
  if (!existsSync(abs)) fail(`${what} not found: ${abs}`);
  return abs;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const fp = args["--family-planner"] as string | undefined;
  const cookless = args["--cookless"] as string | undefined;
  const media = args["--cookless-media"] as string | undefined;
  const fma = args["--fma"] as string | undefined;
  if (!fp && !cookless && !fma) fail(`Name at least one source.\n${USAGE}`);
  if (media && !cookless) fail("--cookless-media needs --cookless");

  // lib/db/client creates the file when it's missing: check first.
  const dbFile = resolve(process.env.DATABASE_FILE ?? "./data/ohana.db");
  if (!existsSync(dbFile)) fail(`No Ohana database at ${dbFile} (set DATABASE_FILE; run npm run db:migrate first).`);

  // Channel tokens are sealed with Ohana's key: a missing secret would seal them with the
  // development fallback, unreadable for the real app.
  if (!args["--dry-run"] && !process.env.AUTH_SECRET && !process.env.ENCRYPTION_KEY) {
    fail("Set Ohana's AUTH_SECRET (and ENCRYPTION_KEY, if it has one): channel tokens are encrypted with it.");
  }

  const map: ImportMap = args["--map"]
    ? (JSON.parse(readFileSync(existing(args["--map"] as string, "Import map"), "utf8")) as ImportMap)
    : { families: [] };
  const sources: ImportSources = {};
  if (fp) sources.familyPlanner = loadFamilyPlannerDump(existing(fp, "family-planner dump"));
  if (cookless) sources.cookless = openCookless(existing(cookless, "cookless database"), media && existing(media, "cookless media folder"));
  if (fma) sources.fma = openFma(existing(fma, "findmyappointment database"));

  const { db, sqlite } = await import("../lib/db/client");
  const { migrationsApplied } = await import("../lib/maintenance/migrations");
  if (!migrationsApplied(sqlite, resolve("drizzle"))) {
    fail(`${dbFile} isn't migrated to this version of Ohana: run npm run db:migrate (or start the web container once).`);
  }
  const { runImport, ImportRefused } = await import("../lib/import");
  const { formatReport } = await import("../lib/import/report");

  try {
    const report = await runImport(db, sources, {
      map,
      dryRun: args["--dry-run"] === true,
      force: args["--force"] === true,
    });
    console.log(formatReport(report));
    if (args["--report"]) writeFileSync(resolve(args["--report"] as string), JSON.stringify(report, null, 2));
  } catch (e) {
    if (e instanceof ImportRefused) fail(`Refused: ${e.message}`);
    console.error(e);
    fail("The import failed; nothing was written.");
  } finally {
    sources.cookless?.db.close();
    sources.fma?.db.close();
  }
}

main().catch((e: unknown) => fail(e instanceof Error ? e.message : String(e)));
