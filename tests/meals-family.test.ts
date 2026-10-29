import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import Database from "better-sqlite3";
import { drizzle } from "drizzle-orm/better-sqlite3";
import { migrate } from "drizzle-orm/better-sqlite3/migrator";
import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import * as schema from "@/lib/db/schema";
import { families, mealPlanEntries, mealPlans, mealTags, planIterations, recipes, shoppingListItems, shoppingLists, ingredients, units } from "@/lib/db/schema";
import { createTestDb } from "@/lib/test/db";
import { makeFamily, makeUser, NOW } from "@/lib/test/factories";
import { DEFAULT_TAG_COUNT } from "@/lib/meals/recipes/tag-defaults";
import { getMealsSummary } from "@/lib/meals/queries/meal-plan";
import { setupPlanSchema } from "@/lib/meals/schemas/mutations";

describe("meal tags of a family", () => {
  it("a new family starts with the default tags", () => {
    const db = createTestDb();
    const family = makeFamily(db, makeUser(db).id);
    const tags = db.select().from(mealTags).where(eq(mealTags.familyId, family.id)).all();
    expect(tags).toHaveLength(DEFAULT_TAG_COUNT);
    expect(tags.every((t) => t.isDefault)).toBe(true);
  });

  it("the meals migration gives families that existed before it the default tags, with uuid ids", () => {
    const dir = mkdtempSync(join(tmpdir(), "ohana-migrations-"));
    try {
      const src = resolve(__dirname, "../drizzle");
      cpSync(src, dir, { recursive: true });
      const journalPath = join(dir, "meta/_journal.json");
      const journal = JSON.parse(readFileSync(journalPath, "utf8")) as { entries: { tag: string }[] };
      const mealsIdx = journal.entries.findIndex((e) => e.tag.endsWith("_meals"));
      expect(mealsIdx).toBeGreaterThan(0);
      writeFileSync(journalPath, JSON.stringify({ ...journal, entries: journal.entries.slice(0, mealsIdx) }));

      const sqlite = new Database(":memory:");
      sqlite.pragma("foreign_keys = ON");
      const db = drizzle(sqlite, { schema });
      migrate(db, { migrationsFolder: dir }); // everything before the meals migration
      sqlite.prepare("insert into families (id, name, created_at, updated_at) values ('f1', 'A', 0, 0), ('f2', 'B', 0, 0)").run();
      migrate(db, { migrationsFolder: src });

      for (const familyId of ["f1", "f2"]) {
        const tags = db.select().from(mealTags).where(eq(mealTags.familyId, familyId)).all();
        expect(tags).toHaveLength(DEFAULT_TAG_COUNT);
        // The plan setup validates excluded tag ids as uuids.
        expect(setupPlanSchema.shape.excludedTagIds.parse(tags.map((t) => t.id))).toHaveLength(DEFAULT_TAG_COUNT);
      }
      const ids = db.select({ id: mealTags.id }).from(mealTags).all().map((t) => t.id);
      expect(new Set(ids).size).toBe(ids.length);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("deleting a family deletes its meals", () => {
    const db = createTestDb();
    const family = makeFamily(db, makeUser(db).id);
    db.insert(recipes).values({ id: "r1", familyId: family.id, title: "Soup", listType: "KNOWN", createdAt: NOW, updatedAt: NOW }).run();
    db.delete(families).where(eq(families.id, family.id)).run();
    expect(db.select().from(recipes).all()).toHaveLength(0);
    expect(db.select().from(mealTags).all()).toHaveLength(0);
  });
});

describe("getMealsSummary", () => {
  function setup() {
    const db = createTestDb();
    const family = makeFamily(db, makeUser(db).id);
    db.insert(units).values({ id: 1, nameEn: "gram", nameDe: "Gramm", abbreviation: "g" }).run();
    db.insert(ingredients).values([
      { id: 1, nameEn: "Tomato", nameDe: "Tomate" },
      { id: 2, nameEn: "Pasta", nameDe: "Nudeln" },
    ]).run();
    db.insert(recipes).values({ id: "r1", familyId: family.id, title: "Soup", listType: "KNOWN", createdAt: NOW, updatedAt: NOW }).run();
    db.insert(mealPlans).values({ id: "mp", familyId: family.id, createdAt: NOW }).run();
    db.insert(planIterations).values({ id: "it", mealPlanId: "mp", startDate: "2026-11-01", endDate: "2026-11-07", createdAt: NOW }).run();
    db.insert(mealPlanEntries).values({ id: "e1", iterationId: "it", date: "2026-11-02", mealType: "LUNCH", recipeId: "r1", servings: 2 }).run();
    db.insert(shoppingLists).values({ id: "sl", iterationId: "it", shoppingDate: "2026-11-06", createdAt: NOW }).run();
    db.insert(shoppingListItems).values([
      { id: "i1", shoppingListId: "sl", ingredientId: 1, quantity: "100", unitId: 1, isChecked: true },
      { id: "i2", shoppingListId: "sl", ingredientId: 2, quantity: "200", unitId: 1 },
    ]).run();
    return { db, family };
  }

  it("shows today's meal and what is left to buy", () => {
    const { db, family } = setup();
    expect(getMealsSummary(db, family.id, "2026-11-02")).toEqual({
      today: { recipeId: "r1", recipeTitle: "Soup", isLeftover: false },
      shopping: { id: "sl", shoppingDate: "2026-11-06", open: 1, total: 2 },
    });
  });

  it("has nothing for a day without a meal, and nothing of another family", () => {
    const { db, family } = setup();
    expect(getMealsSummary(db, family.id, "2026-11-03").today).toBeNull();
    const other = makeFamily(db, makeUser(db).id);
    expect(getMealsSummary(db, other.id, "2026-11-02")).toEqual({ today: null, shopping: null });
  });
});
