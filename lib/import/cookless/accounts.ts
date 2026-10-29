// cookless: users, households → families, members (stage 1), invites (an area).
import { invites } from "@/lib/db/schema";
import { all, bool, openSourceDb, requireSchema, sec, str } from "../sqlite";
import type { CooklessSource, ImportContext, SourceAccounts } from "../types";

const SCHEMA = {
  users: ["id", "email", "password", "preferred_language", "active_household_id", "onboarding_step", "is_active", "is_staff", "created_at"],
  households: ["id", "name", "ai_enabled", "gemini_api_key", "created_at"],
  household_members: ["household_id", "user_id", "role", "joined_at"],
  invites: ["id", "household_id", "created_by_id", "code", "expires_at", "used_by_id", "created_at"],
  tags: ["id", "household_id", "category", "name_en", "name_de", "is_default"],
  recipes: ["id", "household_id", "title", "description", "list_type", "default_servings", "prep_time_minutes", "cook_time_minutes", "leftover_days", "image", "created_at", "updated_at"],
  recipe_ingredients: ["id", "recipe_id", "ingredient_id", "quantity", "unit_id", "order"],
  cooking_steps: ["id", "recipe_id", "method", "step_number", "instruction", "program_type", "temperature", "duration_seconds", "speed", "turbo", "direction", "weight_grams"],
  step_ingredients: ["id", "step_id", "recipe_ingredient_id", "quantity"],
  recipe_tags: ["recipe_id", "tag_id"],
  ingredients: ["id", "name_de", "name_en", "category"],
  units: ["id", "name_de", "name_en", "abbreviation", "base_unit_id", "conversion_factor"],
  meal_plans: ["id", "household_id", "iteration_weeks", "shopping_day_1", "shopping_day_2", "servings", "known_ratio", "default_leftover_days", "created_at"],
  plan_iterations: ["id", "meal_plan_id", "start_date", "end_date", "status", "created_at"],
  meal_plan_entries: ["id", "iteration_id", "date", "meal_type", "recipe_id", "servings", "is_leftover", "source_entry_id", "is_locked"],
  meal_plan_excluded_tags: ["meal_plan_id", "tag_id"],
  shopping_lists: ["id", "iteration_id", "shopping_date", "created_at"],
  shopping_list_items: ["id", "shopping_list_id", "ingredient_id", "quantity", "unit_id", "is_checked"],
};

export function openCookless(path: string, mediaDir?: string): CooklessSource {
  const db = openSourceDb(path, "cookless");
  requireSchema(db, "cookless", SCHEMA);
  return { db, mediaDir };
}

export function readCooklessAccounts(src: CooklessSource, now: Date): SourceAccounts {
  const out: SourceAccounts = { users: [], families: [], members: [] };
  for (const u of all(src.db, "SELECT * FROM users")) {
    out.users.push({
      source: "cookless",
      id: str(u.id),
      email: str(u.email),
      name: "",
      password: str(u.password),
      passwordUnusable:
        u.onboarding_step === "CHANGE_PASSWORD" && u.password ? "cookless's initial password, never changed" : undefined,
      isAdmin: bool(u.is_staff),
      language: str(u.preferred_language, "en"),
      activeFamilyId: (u.active_household_id as string | null) ?? null,
      active: bool(u.is_active),
      createdAt: sec(u.created_at) ?? now,
    });
  }
  for (const h of all(src.db, "SELECT * FROM households")) {
    out.families.push({ source: "cookless", id: str(h.id), name: str(h.name), createdAt: sec(h.created_at) ?? now });
  }
  for (const m of all(src.db, "SELECT * FROM household_members")) {
    out.members.push({
      source: "cookless",
      familyId: str(m.household_id),
      userId: str(m.user_id),
      role: "editor", // OWNER and MEMBER both become editors
      joinedAt: sec(m.joined_at) ?? now,
    });
  }
  return out;
}

/** Open invite codes (not used, not expired) keep working; they make editors, as before. */
export function importCooklessInvites(ctx: ImportContext): void {
  const src = ctx.sources.cookless;
  if (src) importInvites(ctx, "cookless", all(src.db, "SELECT * FROM invites"));
}

/** Shared with findmyappointment, whose invites table is the same. */
export function importInvites(ctx: ImportContext, source: "cookless" | "fma", rows: Record<string, unknown>[]): void {
  const taken = new Set(ctx.db.select({ code: invites.code }).from(invites).all().map((r) => r.code));
  for (const inv of rows) {
    const code = str(inv.code);
    const expiresAt = sec(inv.expires_at);
    if (inv.used_by_id) {
      ctx.skip(source, "invites", code, "already used");
      continue;
    }
    if (!expiresAt || expiresAt.getTime() <= ctx.now.getTime()) {
      ctx.skip(source, "invites", code, "expired");
      continue;
    }
    const familyId = ctx.familyIds[source].get(str(inv.household_id));
    if (!familyId) {
      ctx.skip(source, "invites", code, "its household isn't imported");
      continue;
    }
    if (taken.has(code)) {
      ctx.skip(source, "invites", code, "the code exists already");
      continue;
    }
    taken.add(code);
    ctx.db
      .insert(invites)
      .values({
        id: str(inv.id),
        familyId,
        createdById: ctx.userIds[source].get(str(inv.created_by_id)) ?? null,
        code,
        role: "editor",
        expiresAt,
        usedById: null,
        createdAt: sec(inv.created_at) ?? ctx.now,
      })
      .run();
  }
}
