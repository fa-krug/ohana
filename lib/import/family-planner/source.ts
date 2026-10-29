import { readFileSync } from "node:fs";
import { parsePgDump, type PgRow } from "../pgdump";
import type { FamilyPlannerSource } from "../types";

/** Reads family-planner's `pg_dump --data-only` file. */
export function loadFamilyPlannerDump(path: string): FamilyPlannerSource {
  const tables = parsePgDump(readFileSync(path, "utf8"));
  if (!tables.has("families")) {
    throw new Error(
      `family-planner: ${path} has no data of public.families (is it a pg_dump --data-only of family-planner's database?)`,
    );
  }
  return { tables, used: new Set() };
}

/** The rows of one table of the dump (none when the dump hasn't got it); marks it as read. */
export function fpRows(src: FamilyPlannerSource, table: string): PgRow[] {
  src.used.add(table);
  return src.tables.get(table) ?? [];
}

/** Tables that are never imported, on purpose (not listed as "not imported" in the report). */
export const FP_IGNORED_TABLES = ["auth_challenges", "rate_limits"];
