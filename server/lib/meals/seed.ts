import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { ingredients, units } from "@/lib/db/schema";
import { SEED_INGREDIENTS, SEED_UNITS } from "@/lib/meals/recipes/seed-data";

/** Loads the shared units and ingredients. Idempotent: rows that exist (by unit
 *  abbreviation / ingredient English name) are left alone. Runs at every `web` boot. */
export function seed(db: Db): { units: number; ingredients: number } {
  // --- Units ---
  // Read existing abbreviations to skip already-seeded units
  const existingAbbrs = new Set(db.select({ abbreviation: units.abbreviation }).from(units).all().map((u) => u.abbreviation));

  for (const u of SEED_UNITS) {
    if (!existingAbbrs.has(u.abbreviation)) {
      db.insert(units).values({
        abbreviation: u.abbreviation,
        nameEn: u.nameEn,
        nameDe: u.nameDe,
        conversionFactor: u.conversionFactor,
        // baseUnitId will be set in the second pass
      }).run();
      existingAbbrs.add(u.abbreviation);
    }
  }

  // Second pass: set baseUnitId for units that have a base
  const abbrevToId = new Map(
    db.select({ id: units.id, abbreviation: units.abbreviation }).from(units).all().map((u) => [u.abbreviation, u.id]),
  );

  for (const u of SEED_UNITS) {
    if (u.baseUnitAbbr !== null) {
      const unitId = abbrevToId.get(u.abbreviation);
      const baseId = abbrevToId.get(u.baseUnitAbbr);
      if (unitId !== undefined && baseId !== undefined) {
        const existing = db.select({ baseUnitId: units.baseUnitId }).from(units).where(eq(units.id, unitId)).get();
        if (existing && existing.baseUnitId === null) {
          db.update(units).set({ baseUnitId: baseId }).where(eq(units.id, unitId)).run();
        }
      }
    }
  }

  // --- Ingredients ---
  const existingNameEns = new Set(
    db.select({ nameEn: ingredients.nameEn }).from(ingredients).all().map((i) => i.nameEn),
  );

  for (const ing of SEED_INGREDIENTS) {
    if (!existingNameEns.has(ing.nameEn)) {
      db.insert(ingredients).values({
        nameEn: ing.nameEn,
        nameDe: ing.nameDe,
        category: ing.category,
      }).run();
      existingNameEns.add(ing.nameEn);
    }
  }
  return { units: SEED_UNITS.length, ingredients: SEED_INGREDIENTS.length };
}
