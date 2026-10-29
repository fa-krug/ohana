// findmyappointment: users, households → families (with the home address), members
// (stage 1), invites (an area).
import { importInvites } from "../cookless/accounts";
import { all, bool, coord, openSourceDb, requireSchema, sec, str } from "../sqlite";
import type { FmaSource, ImportContext, SourceAccounts } from "../types";

const SCHEMA = {
  users: ["id", "email", "password", "preferred_language", "active_household_id", "onboarding_step", "is_active", "is_staff", "created_at"],
  households: ["id", "name", "language", "home_address_label", "home_latitude", "home_longitude", "created_at"],
  household_members: ["household_id", "user_id", "role", "joined_at"],
  invites: ["id", "household_id", "created_by_id", "code", "expires_at", "used_by_id", "created_at"],
  notification_channels: ["id", "household_id", "name", "provider", "token", "target", "smtp_host", "smtp_port", "smtp_username", "smtp_from", "enabled", "created_at"],
  searches: [
    "id", "household_id", "name", "speciality_slug", "speciality_label", "location_label", "latitude", "longitude",
    "insurance_sector", "sources", "jameda_speciality_slug", "jameda_speciality_label", "jameda_speciality_type",
    "jameda_insurance_type", "jameda_kids_friendly", "jameda_video", "day_limit", "max_pages", "enabled",
    "schedule_type", "schedule_minutes", "cron", "notify_only_earlier", "earliest_seen", "last_run_at",
    "next_run_at", "last_status", "created_at", "updated_at",
  ],
  search_channels: ["search_id", "channel_id"],
  ignored_entries: ["search_id", "provider_slug", "source", "motive_id", "doctor_name", "motive_label", "created_at"],
};

export function openFma(path: string): FmaSource {
  const db = openSourceDb(path, "findmyappointment");
  requireSchema(db, "findmyappointment", SCHEMA);
  return { db };
}

export function readFmaAccounts(src: FmaSource, now: Date): SourceAccounts {
  const out: SourceAccounts = { users: [], families: [], members: [] };
  for (const u of all(src.db, "SELECT * FROM users")) {
    out.users.push({
      source: "fma",
      id: str(u.id),
      email: str(u.email),
      name: "",
      password: str(u.password),
      passwordUnusable:
        u.onboarding_step === "CHANGE_PASSWORD" && u.password
          ? "findmyappointment's initial password, never changed"
          : undefined,
      isAdmin: bool(u.is_staff),
      language: str(u.preferred_language, "en"),
      activeFamilyId: (u.active_household_id as string | null) ?? null,
      active: bool(u.is_active),
      createdAt: sec(u.created_at) ?? now,
    });
  }
  for (const h of all(src.db, "SELECT * FROM households")) {
    const address = str(h.home_address_label).trim();
    const lat = coord(h.home_latitude);
    const lng = coord(h.home_longitude);
    out.families.push({
      source: "fma",
      id: str(h.id),
      name: str(h.name),
      createdAt: sec(h.created_at) ?? now,
      language: str(h.language, "en"),
      home: address || (lat !== null && lng !== null) ? { address, lat, lng } : undefined,
    });
  }
  for (const m of all(src.db, "SELECT * FROM household_members")) {
    out.members.push({
      source: "fma",
      familyId: str(m.household_id),
      userId: str(m.user_id),
      role: "editor", // OWNER and MEMBER both become editors
      joinedAt: sec(m.joined_at) ?? now,
    });
  }
  return out;
}

export function importFmaInvites(ctx: ImportContext): void {
  const src = ctx.sources.fma;
  if (src) importInvites(ctx, "fma", all(src.db, "SELECT * FROM invites"));
}
