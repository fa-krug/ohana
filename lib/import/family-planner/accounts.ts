// family-planner: users, families, members (stage 1) and API tokens (an area).
import { authTokens } from "@/lib/db/schema";
import { pgBool, pgDate } from "../pgdump";
import type { FamilyPlannerSource, ImportContext, SourceAccounts } from "../types";
import { fpRows } from "./source";

export function readFamilyPlannerAccounts(src: FamilyPlannerSource, now: Date): SourceAccounts {
  const out: SourceAccounts = { users: [], families: [], members: [] };
  for (const u of fpRows(src, "users")) {
    const mustChange = pgBool(u.must_change_password);
    out.users.push({
      source: "familyPlanner",
      id: u.id!,
      email: u.email ?? "",
      name: u.name ?? "",
      password: u.password_hash ?? "",
      passwordUnusable: mustChange && u.password_hash ? "family-planner's initial password, never changed" : undefined,
      isAdmin: pgBool(u.is_admin),
      active: true,
      createdAt: pgDate(u.created_at) ?? now,
    });
  }
  for (const f of fpRows(src, "families")) {
    const createdAt = pgDate(f.created_at) ?? now;
    out.families.push({
      source: "familyPlanner",
      id: f.id!,
      name: f.name ?? "",
      createdAt,
      updatedAt: pgDate(f.updated_at) ?? createdAt,
      feedId: f.feed_id ?? undefined,
      legacyId: f.legacy_id ?? null,
    });
  }
  for (const m of fpRows(src, "family_members")) {
    out.members.push({
      source: "familyPlanner",
      familyId: m.family_id!,
      userId: m.user_id!,
      role: m.role === "editor" ? "editor" : "viewer",
      joinedAt: pgDate(m.created_at) ?? now,
    });
  }
  return out;
}

/** Personal API tokens move as they are: both apps store the SHA-256 (hex) of the token, so
 *  scripts keep their token. Sessions and setup links don't (everyone signs in again; the
 *  admin makes new setup links); passkeys are bound to family-planner's domain. */
export function importFamilyPlannerTokens(ctx: ImportContext): void {
  const src = ctx.sources.familyPlanner;
  if (!src) return;
  let sessions = 0;
  let setups = 0;
  for (const t of fpRows(src, "auth_tokens")) {
    if (t.kind === "session") sessions++;
    else if (t.kind === "setup") setups++;
    if (t.kind !== "api") continue;
    const userId = ctx.userIds.familyPlanner.get(t.user_id ?? "");
    if (!userId) {
      ctx.skip("familyPlanner", "auth_tokens", t.id ?? "", "its user isn't imported");
      continue;
    }
    const expiresAt = pgDate(t.expires_at);
    if (expiresAt && expiresAt.getTime() <= ctx.now.getTime()) {
      ctx.skip("familyPlanner", "auth_tokens", t.name || t.id || "", "expired");
      continue;
    }
    ctx.db
      .insert(authTokens)
      .values({
        id: t.id!,
        hash: t.hash!,
        userId,
        kind: "api",
        name: t.name ?? "",
        canReset: false,
        createdAt: pgDate(t.created_at) ?? ctx.now,
        lastUsedAt: pgDate(t.last_used_at),
        expiresAt,
      })
      .run();
  }
  if (sessions > 0) ctx.skip("familyPlanner", "auth_tokens", `${sessions} session(s)`, "sessions don't move: everyone signs in again");
  if (setups > 0) ctx.skip("familyPlanner", "auth_tokens", `${setups} setup link(s)`, "setup links don't move: make new ones");
  const passkeys = fpRows(src, "passkeys").length;
  if (passkeys > 0) {
    ctx.skip("familyPlanner", "passkeys", `${passkeys} passkey(s)`, "bound to family-planner's domain: add new ones in Ohana");
  }
}
