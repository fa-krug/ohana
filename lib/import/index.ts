// The one-time import of family-planner, cookless and findmyappointment into an empty Ohana
// database (scripts/import-legacy.ts is the command line). See README → "Importing the old
// apps" and docs/plan.md → "Importing the existing data".
//
// Everything that goes into the database happens in one SQLite transaction: all or nothing.
// A dry run does all of it too and rolls back at the end, so its report is what the real run
// would do. Recipe photos are copied inside that transaction and removed again if it fails.
import { rmSync } from "node:fs";
import type Database from "better-sqlite3";
import { count, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { and } from "drizzle-orm";
import { families, familyMembers, finCategories, mealTags, users } from "@/lib/db/schema";
import { insertPresetTypes } from "@/lib/calendar/presets";
import { insertDefaultCategories } from "@/lib/finance/presets";
import { seedDefaultTags } from "@/lib/meals/recipes/tags";
import { mediaRoot as defaultMediaRoot } from "@/lib/meals/images/config";
import { getSecretBox, SecretBox } from "@/lib/secrets";
import { planAccounts, writeAccounts, type AccountsPlan } from "./accounts";
import { importCooklessInvites } from "./cookless/accounts";
import { importCooklessAi } from "./cookless/assistant";
import { importCooklessMeals } from "./cookless/meals";
import { importFamilyPlannerTokens } from "./family-planner/accounts";
import { importFamilyPlannerAiSettings, importFamilyPlannerChats } from "./family-planner/assistant";
import { importFamilyPlannerCalendar } from "./family-planner/calendar";
import { importFamilyPlannerFinance } from "./family-planner/finance";
import { FP_IGNORED_TABLES } from "./family-planner/source";
import { importFmaAppointments } from "./fma/appointments";
import { importFmaInvites } from "./fma/accounts";
import { ImportRefused } from "./errors";
import { hasTable } from "./sqlite";
import type { ImportArea, ImportContext, ImportMap, ImportReport, ImportSources, SourceName } from "./types";

export type { ImportMap, ImportReport, ImportSources } from "./types";

/**
 * The areas, in order; each copies one area of one source (see types.ts). family-planner's
 * AI settings go before cookless's Gemini key, which only fills families without them.
 */
export const AREAS: Array<{ name: string; run: ImportArea }> = [
  { name: "family-planner: API tokens", run: importFamilyPlannerTokens },
  { name: "family-planner: calendar", run: importFamilyPlannerCalendar },
  { name: "family-planner: finance", run: importFamilyPlannerFinance },
  { name: "family-planner: AI settings", run: importFamilyPlannerAiSettings },
  { name: "family-planner: chats", run: importFamilyPlannerChats },
  { name: "cookless: invites", run: importCooklessInvites },
  { name: "cookless: meals", run: importCooklessMeals },
  { name: "cookless: Gemini key", run: importCooklessAi },
  { name: "findmyappointment: invites", run: importFmaInvites },
  { name: "findmyappointment: appointments", run: importFmaAppointments },
];

export { ImportRefused } from "./errors";

export interface ImportOptions {
  map?: ImportMap;
  dryRun?: boolean;
  /** Import into a database that has accounts or families already (e.g. the admin made at
   *  /setup): existing accounts with the same email are kept and get the memberships. */
  force?: boolean;
  now?: Date;
  secrets?: SecretBox;
  /** family-planner's AI_CONFIG_KEY (32 bytes, base64): opens its AI keys to seal them again
   *  with Ohana's. Without it the AI settings come over without keys. */
  familyPlannerAiSecret?: string;
  mediaRoot?: string;
}

/** Refuses a target that isn't empty, unless `force`. */
export function checkTarget(db: Db, force: boolean): void {
  const nUsers = db.select({ n: count() }).from(users).get()!.n;
  const nFamilies = db.select({ n: count() }).from(families).get()!.n;
  if ((nUsers > 0 || nFamilies > 0) && !force) {
    throw new ImportRefused(
      `The Ohana database isn't empty (${nUsers} account(s), ${nFamilies} famil${nFamilies === 1 ? "y" : "ies"}). ` +
        "The import is meant for a fresh database; pass --force to import next to what is there " +
        "(accounts with the same email are kept and get the memberships).",
    );
  }
}

function tableCounts(sqlite: Database.Database): Record<string, number> {
  const tables = sqlite
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '__drizzle%' ORDER BY name")
    .all() as Array<{ name: string }>;
  return Object.fromEntries(
    tables.map((t) => [t.name, (sqlite.prepare(`SELECT count(*) AS n FROM "${t.name}"`).get() as { n: number }).n]),
  );
}

class Rollback extends Error {}

/** New families get what `createFamily` gives them, unless the import brought it: the
 *  preset calendar types (only families that don't come from family-planner, whose calendar
 *  is taken as it was), the default finance categories (only families without
 *  family-planner categories) and the default meal tags (only families without cookless
 *  tags). Presets and categories are named in the family's language. */
function addDefaults(ctx: ImportContext, plan: AccountsPlan): void {
  const { db } = ctx;
  for (const f of plan.families) {
    const lang = familyLanguage(ctx, f.id, f.language);
    if (!ctx.calendarFamilies.has(f.id)) insertPresetTypes(db, f.id, lang, ctx.now.getUTCFullYear());
    const categories = db.select({ n: count() }).from(finCategories).where(eq(finCategories.familyId, f.id)).get()!.n;
    if (categories === 0) insertDefaultCategories(db, f.id, lang);
    const tags = db.select({ n: count() }).from(mealTags).where(eq(mealTags.familyId, f.id)).get()!.n;
    if (tags === 0) seedDefaultTags(db, f.id);
  }
}

/** findmyappointment's household language, else the language of the longest-standing editor. */
function familyLanguage(ctx: ImportContext, familyId: string, own?: string): "en" | "de" {
  if (own === "de" || own === "en") return own;
  const editor = ctx.db
    .select({ lang: users.preferredLanguage })
    .from(familyMembers)
    .innerJoin(users, eq(users.id, familyMembers.userId))
    .where(and(eq(familyMembers.familyId, familyId), eq(familyMembers.role, "editor")))
    .orderBy(familyMembers.joinedAt)
    .all()[0];
  return editor?.lang === "de" ? "de" : "en";
}

function noteLeftovers(ctx: ImportContext): void {
  const fp = ctx.sources.familyPlanner;
  if (fp) {
    const rest = [...fp.tables.entries()]
      .filter(([t, rows]) => rows.length > 0 && !fp.used.has(t) && !FP_IGNORED_TABLES.includes(t))
      .map(([t, rows]) => `${t} (${rows.length})`);
    if (rest.length > 0) ctx.note(`family-planner tables not imported: ${rest.join(", ")}`);
  }
  for (const s of ["cookless", "fma"] as const) {
    const src = ctx.sources[s];
    if (!src || !hasTable(src.db, "passkey_credentials")) continue;
    const n = (src.db.prepare("SELECT count(*) AS n FROM passkey_credentials").get() as { n: number }).n;
    if (n > 0) ctx.skip(s, "passkey_credentials", `${n} passkey(s)`, "bound to the old app's domain: add new ones in Ohana");
  }
}

/**
 * Imports the sources into `db` (which must be migrated). Throws ImportRefused when the
 * target isn't empty (without `force`) or was imported into before, and any other error when
 * a row can't be written; in every failure case nothing is written.
 */
export async function runImport(db: Db, sources: ImportSources, opts: ImportOptions = {}): Promise<ImportReport> {
  const now = opts.now ?? new Date();
  const dryRun = opts.dryRun ?? false;
  const sqlite = (db as unknown as { $client: Database.Database }).$client;
  checkTarget(db, opts.force ?? false);
  let familyPlannerSecrets: SecretBox | null = null;
  if (opts.familyPlannerAiSecret) {
    try {
      familyPlannerSecrets = new SecretBox(opts.familyPlannerAiSecret);
    } catch {
      throw new ImportRefused("The family-planner AI secret must be 32 bytes, base64-encoded (family-planner's AI_CONFIG_KEY).");
    }
  }

  const report: ImportReport = { dryRun, counts: {}, users: [], families: [], skipped: [], notes: [], media: { copied: 0, missing: [] }, aiKeys: [] };
  const skip = (source: SourceName, table: string, key: string, reason: string) =>
    report.skipped.push({ source, table, key, reason });
  const note = (message: string) => report.notes.push(message);

  // Reading the sources and checking the passwords happens before the transaction (async).
  const plan = await planAccounts(sources, opts.map ?? { families: [] }, now, { skip, note });

  const ctx: ImportContext = {
    db,
    now,
    sources,
    dryRun,
    secrets: opts.secrets ?? getSecretBox(),
    familyPlannerSecrets,
    mediaRoot: opts.mediaRoot ?? defaultMediaRoot(),
    userIds: { familyPlanner: new Map(), cookless: new Map(), fma: new Map() },
    familyIds: { familyPlanner: new Map(), cookless: new Map(), fma: new Map() },
    calendarFamilies: new Set(),
    report,
    copiedFiles: [],
    skip,
    note,
  };

  if (!(sqlite.pragma("foreign_keys", { simple: true }) as number)) sqlite.pragma("foreign_keys = ON");
  const before = tableCounts(sqlite);
  try {
    sqlite.transaction(() => {
      // Rows may refer to rows written later in the same import; checked before the end.
      sqlite.pragma("defer_foreign_keys = ON");
      writeAccounts(ctx, plan);
      for (const area of AREAS) {
        try {
          area.run(ctx);
        } catch (e) {
          throw new Error(`${area.name}: ${e instanceof Error ? e.message : String(e)}`, { cause: e });
        }
      }
      addDefaults(ctx, plan);
      noteLeftovers(ctx);
      const broken = sqlite.pragma("foreign_key_check") as Array<{ table: string; parent: string }>;
      if (broken.length > 0) {
        const sample = broken.slice(0, 5).map((b) => `${b.table} → ${b.parent}`).join(", ");
        throw new Error(`${broken.length} row(s) refer to missing rows (${sample})`);
      }
      const after = tableCounts(sqlite);
      for (const [t, n] of Object.entries(after)) if (n !== (before[t] ?? 0)) report.counts[t] = n - (before[t] ?? 0);
      if (dryRun) throw new Rollback();
    })();
  } catch (e) {
    for (const file of ctx.copiedFiles) rmSync(file, { force: true });
    if (e instanceof Rollback) return report;
    throw e;
  }
  return report;
}
