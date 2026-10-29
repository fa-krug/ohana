// Shared types of the legacy import (scripts/import-legacy.ts).
//
// The import runs in two stages:
// 1. Accounts (`accounts.ts`): every source says who its users, families and members are
//    (`SourceAccounts`, read by `<source>/accounts.ts`); they are merged — users by email,
//    families by the import map — and written. That fills `ctx.userIds` / `ctx.familyIds`,
//    which translate a source's ids into Ohana's.
// 2. Areas (`AREAS` in `index.ts`): one function per source and area (calendar, meals,
//    appointments, the assistant, …) copies its rows, looking up users and families in those maps.
import type Database from "better-sqlite3";
import type { Db } from "@/lib/db";
import type { SecretBox } from "@/lib/secrets";
import type { PgTables } from "./pgdump";

export type SourceName = "familyPlanner" | "cookless" | "fma";
export const SOURCE_NAMES: SourceName[] = ["familyPlanner", "cookless", "fma"];
export const SOURCE_LABEL: Record<SourceName, string> = {
  familyPlanner: "family-planner",
  cookless: "cookless",
  fma: "findmyappointment",
};

export interface FamilyPlannerSource {
  /** Rows per `public` table of the pg_dump. */
  tables: PgTables;
  /** Tables an importer has read (the report lists the dump's other tables as not imported). */
  used: Set<string>;
}

export interface CooklessSource {
  db: Database.Database;
  /** cookless's media folder (holds `recipes/…`); without it recipes lose their photos. */
  mediaDir?: string;
}

export interface FmaSource {
  db: Database.Database;
}

export interface ImportSources {
  familyPlanner?: FamilyPlannerSource;
  cookless?: CooklessSource;
  fma?: FmaSource;
}

/** import-map.json: which cookless / findmyappointment household is which family, and
 *  (`skip`) the families and households that aren't imported at all. */
export interface ImportMap {
  families: Array<{ familyPlanner?: string; cookless?: string; fma?: string }>;
  skip?: Array<{ familyPlanner?: string; cookless?: string; fma?: string }>;
}

// ---- stage 1: what each source says about accounts ----

export interface SourceUser {
  source: SourceName;
  id: string;
  email: string;
  name: string;
  /** The password hash, or "" for none. */
  password: string;
  /** Why `password` must not be carried over (e.g. a temporary one), if so. */
  passwordUnusable?: string;
  isAdmin: boolean;
  /** "en" | "de", where the source has one. */
  language?: string;
  /** The source family the user had open (cookless / findmyappointment). */
  activeFamilyId?: string | null;
  /** Inactive accounts aren't imported. */
  active: boolean;
  createdAt: Date;
}

export interface SourceFamily {
  source: SourceName;
  id: string;
  name: string;
  createdAt: Date;
  updatedAt?: Date;
  feedId?: string;
  legacyId?: string | null;
  home?: { address: string; lat: number | null; lng: number | null };
  language?: string;
}

export interface SourceMember {
  source: SourceName;
  familyId: string;
  userId: string;
  role: "editor" | "viewer";
  joinedAt: Date;
}

export interface SourceAccounts {
  users: SourceUser[];
  families: SourceFamily[];
  members: SourceMember[];
}

// ---- the report ----

export interface ReportUser {
  email: string;
  id: string;
  from: SourceName[];
  passwordFrom: SourceName | null;
  isAdmin: boolean;
  /** No password came over: the account needs a setup link. */
  needsSetupLink: boolean;
  /** --force: the account existed in Ohana already and was kept as it was. */
  existing?: boolean;
}

export interface ReportFamily {
  id: string;
  name: string;
  from: Partial<Record<SourceName, string>>;
  members: Array<{ email: string; role: string }>;
}

export interface ImportReport {
  dryRun: boolean;
  /** Rows the import added, per Ohana table. */
  counts: Record<string, number>;
  users: ReportUser[];
  families: ReportFamily[];
  skipped: Array<{ source: SourceName; table: string; key: string; reason: string }>;
  notes: string[];
  media: { copied: number; missing: string[] };
  /** Families whose AI keys didn't come over (they have to be entered again). */
  aiKeys: Array<{ familyId: string; family: string; keys: string[]; reason: string }>;
}

// ---- stage 2: the context every area gets ----

export interface ImportContext {
  /** The target database, inside the import's transaction. */
  db: Db;
  now: Date;
  sources: ImportSources;
  dryRun: boolean;
  /** Seals secrets with Ohana's key (lib/secrets.ts). */
  secrets: SecretBox;
  /** Opens family-planner's AI keys (its AI_CONFIG_KEY), if given. */
  familyPlannerSecrets: SecretBox | null;
  /** Ohana's MEDIA_ROOT. */
  mediaRoot: string;
  /** Source id → Ohana id, per source. */
  userIds: Record<SourceName, Map<string, string>>;
  familyIds: Record<SourceName, Map<string, string>>;
  /** Ohana families that got their calendar from family-planner (they get no preset types). */
  calendarFamilies: Set<string>;
  report: ImportReport;
  /** Files written into MEDIA_ROOT; removed again when the transaction fails. */
  copiedFiles: string[];
  skip(source: SourceName, table: string, key: string, reason: string): void;
  note(message: string): void;
}

/** One area of one source: copies its rows into the target (inside the transaction). */
export type ImportArea = (ctx: ImportContext) => void;
