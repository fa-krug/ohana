// family-planner: the calendar (entry types per year, day entries, day notes).
import { calEntries, calEntryTypes, calNotes } from "@/lib/db/schema";
import { pgDay, pgInt } from "../pgdump";
import type { ImportContext } from "../types";
import { fpRows } from "./source";

const ROLES = new Set(["none", "needs_cover", "covers", "day_off"]);

export function importFamilyPlannerCalendar(ctx: ImportContext): void {
  const src = ctx.sources.familyPlanner;
  if (!src) return;
  const family = (id: string | null) => ctx.familyIds.familyPlanner.get(id ?? "");

  const types = new Set<string>();
  for (const t of fpRows(src, "entry_types")) {
    const familyId = family(t.family_id);
    if (!familyId) {
      ctx.skip("familyPlanner", "entry_types", `${t.family_id}/${t.year}/${t.id}`, "its family isn't imported");
      continue;
    }
    const year = pgInt(t.year);
    ctx.db
      .insert(calEntryTypes)
      .values({
        familyId,
        year,
        id: t.id!,
        name: t.name ?? "",
        color: t.color ?? "#64748b",
        role: ROLES.has(t.role ?? "") ? t.role! : "none",
        position: pgInt(t.position),
      })
      .run();
    types.add(`${familyId}|${year}|${t.id}`);
  }

  for (const e of fpRows(src, "day_entries")) {
    const familyId = family(e.family_id);
    const day = pgDay(e.day);
    if (!familyId || !day) {
      ctx.skip("familyPlanner", "day_entries", `${e.family_id}/${e.day}`, familyId ? "no valid day" : "its family isn't imported");
      continue;
    }
    const year = Number(day.slice(0, 4));
    if (!types.has(`${familyId}|${year}|${e.type_id}`)) {
      ctx.skip("familyPlanner", "day_entries", `${e.family_id}/${day}/${e.type_id}`, "its type doesn't exist in that year");
      continue;
    }
    ctx.db.insert(calEntries).values({ familyId, day, year, typeId: e.type_id! }).run();
  }

  for (const n of fpRows(src, "day_notes")) {
    const familyId = family(n.family_id);
    const day = pgDay(n.day);
    if (!familyId || !day) {
      ctx.skip("familyPlanner", "day_notes", `${n.family_id}/${n.day}`, familyId ? "no valid day" : "its family isn't imported");
      continue;
    }
    ctx.db.insert(calNotes).values({ familyId, day, icon: n.icon ?? "", comment: n.comment ?? "" }).run();
  }
}
