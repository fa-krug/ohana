// Small cookless and findmyappointment databases for the import tests, made by applying the
// apps' real migrations (copied to tests/fixtures/legacy/*/drizzle) and inserting rows.
// family-planner's counterpart is the hand-written dump tests/fixtures/legacy/family-planner.sql.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import Database from "better-sqlite3";
import { drizzle } from "drizzle-orm/better-sqlite3";
import { migrate } from "drizzle-orm/better-sqlite3/migrator";
import { hashPassword } from "@/lib/auth/password";

const fixtures = resolve(dirname(fileURLToPath(import.meta.url)), "../../tests/fixtures/legacy");
export const FP_DUMP = join(fixtures, "family-planner.sql");

/** Ids of the family-planner fixture. */
export const FP = {
  krug: "fpKrugFamily00000001",
  oma: "fpOmaFamily000000002",
  anna: "fpUserAnna000000001",
  apiToken: "fp_test_api_token",
  annaPassword: "anna-fp-pass",
};

export const CK = {
  krug: "11111111-1111-4111-8111-111111111111",
  carl: "22222222-2222-4222-8222-222222222222",
  anna: "c0000000-0000-4000-8000-00000000000a",
  ben: "c0000000-0000-4000-8000-00000000000b",
  carlUser: "c0000000-0000-4000-8000-00000000000c",
  dora: "c0000000-0000-4000-8000-00000000000d",
  vegetarian: "t0000000-0000-4000-8000-000000000001",
  italian: "t0000000-0000-4000-8000-000000000002",
  pasta: "r0000000-0000-4000-8000-000000000001",
  salad: "r0000000-0000-4000-8000-000000000002",
  soup: "r0000000-0000-4000-8000-000000000003",
  plan: "p0000000-0000-4000-8000-000000000001",
  iteration: "i0000000-0000-4000-8000-000000000001",
  entry: "e0000000-0000-4000-8000-000000000001",
  leftover: "e0000000-0000-4000-8000-000000000002",
  list: "l0000000-0000-4000-8000-000000000001",
  item: "s0000000-0000-4000-8000-000000000001",
  pastaImage: "recipes/r0000000-0000-4000-8000-000000000001_1700000000000.webp",
  benPassword: "ben-cookless-pass",
};

export const FMA = {
  krug: "33333333-3333-4333-8333-333333333333",
  erik: "44444444-4444-4444-8444-444444444444",
  anna: "f0000000-0000-4000-8000-00000000000a",
  erikUser: "f0000000-0000-4000-8000-00000000000e",
  pushover: "ch000000-0000-4000-8000-000000000001",
  email: "ch000000-0000-4000-8000-000000000002",
  derm: "se000000-0000-4000-8000-000000000001",
  dentist: "se000000-0000-4000-8000-000000000002",
};

const T0 = 1_700_000_000; // seconds, as Drizzle stores timestamps
const DAY = 86_400;

function open(path: string, app: "cookless" | "fma"): Database.Database {
  mkdirSync(dirname(path), { recursive: true });
  const sqlite = new Database(path);
  migrate(drizzle(sqlite), { migrationsFolder: join(fixtures, app, "drizzle") });
  return sqlite;
}

/** cookless.db in `dir`, plus a media folder with the pasta's photo. `now` decides which
 *  invites are still open. */
export async function makeCooklessDb(dir: string, nowSec: number): Promise<{ path: string; mediaDir: string }> {
  const path = join(dir, "cookless.db");
  const db = open(path, "cookless");
  const ins = (sql: string, ...args: unknown[]) => db.prepare(sql).run(...args);

  ins("INSERT INTO households (id, name, ai_enabled, gemini_api_key, created_at) VALUES (?, ?, 1, ?, ?)", CK.krug, "Krug Küche", "AIzaFakeGeminiKey", T0);
  ins("INSERT INTO households (id, name, created_at) VALUES (?, ?, ?)", CK.carl, "Carls Küche", T0 + DAY);
  const user = (id: string, email: string, password: string, extra: { step?: string; active?: number; lang?: string; household?: string } = {}) =>
    ins(
      "INSERT INTO users (id, email, password, preferred_language, active_household_id, onboarding_step, is_active, is_staff, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)",
      id, email, password, extra.lang ?? "en", extra.household ?? null, extra.step ?? "COMPLETED", extra.active ?? 1, T0 - DAY * 400,
    );
  user(CK.anna, "Anna@Example.com", await hashPassword("anna-cookless-pass"), { lang: "de", household: CK.krug });
  user(CK.ben, "ben@example.com", await hashPassword(CK.benPassword), { household: CK.krug });
  user(CK.carlUser, "carl@example.com", await hashPassword("temporary-1"), { step: "CHANGE_PASSWORD", household: CK.carl });
  user(CK.dora, "dora@example.com", await hashPassword("dora-pass-1"), { active: 0 });
  const member = (h: string, u: string, role: string) =>
    ins("INSERT INTO household_members (household_id, user_id, role, joined_at) VALUES (?, ?, ?, ?)", h, u, role, T0);
  member(CK.krug, CK.anna, "OWNER");
  member(CK.krug, CK.ben, "MEMBER");
  member(CK.carl, CK.carlUser, "OWNER");
  member(CK.carl, CK.dora, "MEMBER");

  const invite = (id: string, code: string, expires: number, usedBy: string | null) =>
    ins("INSERT INTO invites (id, household_id, created_by_id, code, expires_at, used_by_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      id, CK.krug, CK.anna, code, expires, usedBy, T0);
  invite("inv-open", "OPENCODE", nowSec + DAY, null);
  invite("inv-expired", "OLDCODE", nowSec - DAY, null);
  invite("inv-used", "USEDCODE", nowSec + DAY, CK.ben);

  // Shared data with cookless's own ids: Tomato and g exist in Ohana (other ids), the others not.
  ins("INSERT INTO ingredients (id, name_de, name_en, category) VALUES (7, 'Tomate', 'Tomato', 'PRODUCE')");
  ins("INSERT INTO ingredients (id, name_de, name_en, category) VALUES (8, 'Drachenfrucht', 'Dragonfruit', 'PRODUCE')");
  ins("INSERT INTO units (id, name_de, name_en, abbreviation, base_unit_id, conversion_factor) VALUES (3, 'Gramm', 'gram', 'g', NULL, '1')");
  ins("INSERT INTO units (id, name_de, name_en, abbreviation, base_unit_id, conversion_factor) VALUES (4, 'Kilogramm', 'kilogram', 'kg', 3, '1000')");

  ins("INSERT INTO tags (id, household_id, category, name_en, name_de, is_default) VALUES (?, ?, 'DIETARY', 'Vegetarian', 'Vegetarisch', 1)", CK.vegetarian, CK.krug);
  ins("INSERT INTO tags (id, household_id, category, name_en, name_de, is_default) VALUES (?, ?, 'CUISINE', 'Italian', 'Italienisch', 0)", CK.italian, CK.krug);

  const recipe = (id: string, household: string, title: string, image: string) =>
    ins("INSERT INTO recipes (id, household_id, title, description, list_type, default_servings, prep_time_minutes, cook_time_minutes, leftover_days, image, created_at, updated_at) VALUES (?, ?, ?, 'Lecker', 'KNOWN', 4, 10, NULL, 1, ?, ?, ?)",
      id, household, title, image, T0, T0 + DAY);
  recipe(CK.pasta, CK.krug, "Pasta", CK.pastaImage);
  recipe(CK.salad, CK.krug, "Salat", "recipes/missing.webp");
  recipe(CK.soup, CK.carl, "Suppe", "");
  ins("INSERT INTO recipe_ingredients (id, recipe_id, ingredient_id, quantity, unit_id, \"order\") VALUES (100, ?, 7, '250', 3, 0)", CK.pasta);
  ins("INSERT INTO recipe_ingredients (id, recipe_id, ingredient_id, quantity, unit_id, \"order\") VALUES (101, ?, 8, '0.5', 4, 1)", CK.pasta);
  ins("INSERT INTO cooking_steps (id, recipe_id, method, step_number, instruction, temperature, duration_seconds, speed, turbo) VALUES (200, ?, 'MACHINE', 1, 'Tomaten zerkleinern', 100, 300, 5, 1)", CK.pasta);
  ins("INSERT INTO step_ingredients (id, step_id, recipe_ingredient_id, quantity) VALUES (300, 200, 100, '250')");
  ins("INSERT INTO recipe_tags (recipe_id, tag_id) VALUES (?, ?)", CK.pasta, CK.vegetarian);

  ins("INSERT INTO meal_plans (id, household_id, iteration_weeks, shopping_day_1, servings, known_ratio, default_leftover_days, created_at) VALUES (?, ?, 1, 5, 3, '0.6', 1, ?)", CK.plan, CK.krug, T0);
  ins("INSERT INTO meal_plan_excluded_tags (meal_plan_id, tag_id) VALUES (?, ?)", CK.plan, CK.italian);
  ins("INSERT INTO plan_iterations (id, meal_plan_id, start_date, end_date, status, created_at) VALUES (?, ?, '2026-10-26', '2026-11-01', 'ACTIVE', ?)", CK.iteration, CK.plan, T0);
  ins("INSERT INTO meal_plan_entries (id, iteration_id, date, meal_type, recipe_id, servings, is_leftover, source_entry_id, is_locked) VALUES (?, ?, '2026-10-26', 'DINNER', ?, 3, 0, NULL, 1)", CK.entry, CK.iteration, CK.pasta);
  ins("INSERT INTO meal_plan_entries (id, iteration_id, date, meal_type, recipe_id, servings, is_leftover, source_entry_id, is_locked) VALUES (?, ?, '2026-10-27', 'DINNER', ?, 3, 1, ?, 0)", CK.leftover, CK.iteration, CK.pasta, CK.entry);
  ins("INSERT INTO shopping_lists (id, iteration_id, shopping_date, created_at) VALUES (?, ?, '2026-10-30', ?)", CK.list, CK.iteration, T0);
  ins("INSERT INTO shopping_list_items (id, shopping_list_id, ingredient_id, quantity, unit_id, is_checked) VALUES (?, ?, 8, '1', 4, 1)", CK.item, CK.list);
  ins("INSERT INTO passkey_credentials (id, user_id, credential_id, public_key, created_at) VALUES ('pk1', ?, x'01', x'02', ?)", CK.anna, T0);
  db.close();

  const mediaDir = join(dir, "media");
  mkdirSync(join(mediaDir, "recipes"), { recursive: true });
  writeFileSync(join(mediaDir, CK.pastaImage), Buffer.from("RIFF-fake-webp-pasta"));
  return { path, mediaDir };
}

export async function makeFmaDb(dir: string): Promise<string> {
  const path = join(dir, "fma.db");
  const db = open(path, "fma");
  const ins = (sql: string, ...args: unknown[]) => db.prepare(sql).run(...args);

  ins("INSERT INTO households (id, name, language, home_address_label, home_latitude, home_longitude, created_at) VALUES (?, 'Krug', 'de', 'Hauptstraße 1, Berlin', '52.52', '13.405', ?)", FMA.krug, T0);
  ins("INSERT INTO households (id, name, language, created_at) VALUES (?, 'Erik', 'de', ?)", FMA.erik, T0);
  const user = (id: string, email: string, password: string, staff: number) =>
    ins("INSERT INTO users (id, email, password, preferred_language, onboarding_step, is_active, is_staff, created_at) VALUES (?, ?, ?, 'de', 'COMPLETED', 1, ?, ?)",
      id, email, password, staff, T0 - DAY * 500);
  user(FMA.anna, "anna@example.com", await hashPassword("anna-fma-pass"), 1);
  user(FMA.erikUser, "erik@example.com", await hashPassword("password"), 0); // the Django import's default
  ins("INSERT INTO household_members (household_id, user_id, role, joined_at) VALUES (?, ?, 'OWNER', ?)", FMA.krug, FMA.anna, T0);
  ins("INSERT INTO household_members (household_id, user_id, role, joined_at) VALUES (?, ?, 'OWNER', ?)", FMA.erik, FMA.erikUser, T0);

  ins("INSERT INTO notification_channels (id, household_id, name, provider, token, target, enabled, created_at) VALUES (?, ?, 'Handy', 'PUSHOVER', 'pushover-secret', 'user-key', 1, ?)", FMA.pushover, FMA.krug, T0);
  ins("INSERT INTO notification_channels (id, household_id, name, provider, token, target, smtp_host, smtp_port, smtp_username, smtp_from, enabled, created_at) VALUES (?, ?, 'Mail', 'EMAIL', 'smtp-password', 'anna@example.com', 'smtp.example.com', 587, 'anna', 'fma@example.com', 0, ?)", FMA.email, FMA.krug, T0);

  const search = (id: string, household: string, name: string, enabled: number) =>
    ins(`INSERT INTO searches (id, household_id, name, speciality_slug, speciality_label, location_label, latitude, longitude,
          insurance_sector, sources, jameda_speciality_slug, jameda_speciality_label, jameda_speciality_type, jameda_kids_friendly,
          jameda_video, day_limit, max_pages, enabled, schedule_type, schedule_minutes, cron, notify_only_earlier, earliest_seen,
          last_run_at, next_run_at, last_status, created_at, updated_at)
        VALUES (?, ?, ?, 'hautarzt', 'Hautarzt', 'Berlin', '52.52', '13.405', 'public', 'both', 'hautarzt', 'Hautarzt', 'fachgebiet', 1,
          'hide', 21, 2, ?, 'MINUTES', 45, '', 1, ?, ?, ?, 'OK', ?, ?)`,
      id, household, name, enabled, T0 + DAY * 30, T0, T0 + 2700, T0, T0 + DAY);
  search(FMA.derm, FMA.krug, "Hautarzt", 1);
  search(FMA.dentist, FMA.erik, "Zahnarzt", 0);
  ins("INSERT INTO search_channels (search_id, channel_id) VALUES (?, ?)", FMA.derm, FMA.pushover);
  ins("INSERT INTO ignored_entries (search_id, provider_slug, source, motive_id, doctor_name, motive_label, created_at) VALUES (?, 'dr-x', 'jameda', 42, 'Dr. X', 'Erstbesuch', ?)", FMA.derm, T0);
  ins("INSERT INTO search_runs (id, search_id, started_at, status) VALUES ('run1', ?, ?, 'OK')", FMA.derm, T0);
  ins("INSERT INTO appointment_results (run_id, doctor_name, booking_url, slot_datetime) VALUES ('run1', 'Dr. Y', 'https://x', ?)", T0 + DAY);
  db.close();
  return path;
}

/** The import map of the fixtures: the Krug family exists in all three apps. */
export const MAP = { families: [{ familyPlanner: FP.krug, cookless: CK.krug, fma: FMA.krug }] };
