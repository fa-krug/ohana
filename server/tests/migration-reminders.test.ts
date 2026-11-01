// The migration that moved the shopping list to Reminders (drizzle/0011_reminders_shopping.sql):
// the stored shopping lists, the finance link's setting and the shopping reminder's
// preferences go; everything else stays.

import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import Database from "better-sqlite3";
import { drizzle } from "drizzle-orm/better-sqlite3";
import { migrate } from "drizzle-orm/better-sqlite3/migrator";
import { describe, expect, it } from "vitest";
import * as schema from "@/lib/db/schema";
import { createTestDb } from "@/lib/test/db";

const tables = (sqlite: Database.Database) =>
  (sqlite.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all() as { name: string }[]).map((r) => r.name);
const columns = (sqlite: Database.Database, table: string) =>
  (sqlite.prepare(`PRAGMA table_info(${table})`).all() as { name: string }[]).map((r) => r.name);

describe("the Reminders migration", () => {
  it("leaves no shopping tables and no groceries setting in a new database", () => {
    const db = createTestDb();
    const sqlite = (db as unknown as { $client: Database.Database }).$client;
    expect(tables(sqlite).filter((t) => t.startsWith("shopping"))).toEqual([]);
    expect(columns(sqlite, "fin_settings")).not.toContain("groceries_category_id");
  });

  it("drops the shopping lists and the shopping reminder's preferences of an existing database", () => {
    const dir = mkdtempSync(join(tmpdir(), "ohana-migrations-"));
    try {
      const src = resolve(__dirname, "../drizzle");
      cpSync(src, dir, { recursive: true });
      const journalPath = join(dir, "meta/_journal.json");
      const journal = JSON.parse(readFileSync(journalPath, "utf8")) as { entries: { tag: string }[] };
      const idx = journal.entries.findIndex((e) => e.tag === "0011_reminders_shopping");
      expect(idx).toBeGreaterThan(0);
      writeFileSync(journalPath, JSON.stringify({ ...journal, entries: journal.entries.slice(0, idx) }));

      const sqlite = new Database(":memory:");
      sqlite.pragma("foreign_keys = ON");
      const db = drizzle(sqlite, { schema });
      migrate(db, { migrationsFolder: dir }); // everything before it
      const now = Date.now();
      sqlite.exec(`
        INSERT INTO families (id, feed_id, name, created_at, updated_at) VALUES ('f', 'feed', 'Home', ${now}, ${now});
        INSERT INTO meal_plans (id, family_id, created_at) VALUES ('mp', 'f', ${now});
        INSERT INTO plan_iterations (id, meal_plan_id, start_date, end_date, status, created_at)
          VALUES ('it', 'mp', '2026-11-01', '2026-11-07', 'ACTIVE', ${now});
        INSERT INTO units (id, name_en, name_de, abbreviation) VALUES (1, 'gram', 'Gramm', 'g');
        INSERT INTO ingredients (id, name_en, name_de) VALUES (1, 'Tomato', 'Tomate');
        INSERT INTO shopping_lists (id, iteration_id, shopping_date, created_at) VALUES ('sl', 'it', '2026-11-02', ${now});
        INSERT INTO shopping_list_items (id, shopping_list_id, ingredient_id, quantity, unit_id) VALUES ('i', 'sl', 1, '100', 1);
        INSERT INTO shopping_item_adds (shopping_list_id, client_id, item_id, merged) VALUES ('sl', 'c', 'i', 0);
        INSERT INTO fin_settings (family_id, currency, groceries_category_id) VALUES ('f', 'CHF', 'groceries');
        INSERT INTO notification_prefs (family_id, event, enabled, updated_at) VALUES ('f', 'shopping_reminder', 1, ${now});
        INSERT INTO notification_prefs (family_id, event, enabled, updated_at) VALUES ('f', 'coverage_gap', 0, ${now});
      `);

      migrate(db, { migrationsFolder: src });
      expect(tables(sqlite).filter((t) => t.startsWith("shopping"))).toEqual([]);
      expect(columns(sqlite, "fin_settings")).not.toContain("groceries_category_id");
      expect(sqlite.prepare("SELECT family_id, currency FROM fin_settings").all()).toEqual([{ family_id: "f", currency: "CHF" }]);
      expect(sqlite.prepare("SELECT event FROM notification_prefs").all()).toEqual([{ event: "coverage_gap" }]);
      // The plan itself stays.
      expect(sqlite.prepare("SELECT id FROM plan_iterations").all()).toEqual([{ id: "it" }]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
