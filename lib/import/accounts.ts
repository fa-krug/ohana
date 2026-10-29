// Stage 1 of the import: users merged by email, families by the import map, members combined.
import { randomUUID } from "node:crypto";
import { eq, inArray } from "drizzle-orm";
import { families, familyMembers, users } from "@/lib/db/schema";
import { randomToken } from "@/lib/api/http";
import { verifyPassword } from "@/lib/auth/password";
import { ImportRefused } from "./errors";
import { readCooklessAccounts } from "./cookless/accounts";
import { readFamilyPlannerAccounts } from "./family-planner/accounts";
import { readFmaAccounts } from "./fma/accounts";
import {
  SOURCE_LABEL,
  SOURCE_NAMES,
  type ImportContext,
  type ImportMap,
  type ImportSources,
  type SourceAccounts,
  type SourceFamily,
  type SourceMember,
  type SourceName,
  type SourceUser,
} from "./types";

/** Passwords that are a known default somewhere (family-planner's admin/admin, the
 *  "password" findmyappointment's Django import gave everyone): never carried over. */
const DEFAULT_PASSWORDS = ["admin", "password"];

export interface PlannedUser {
  id: string;
  email: string;
  name: string;
  password: string;
  passwordFrom: SourceName | null;
  isAdmin: boolean;
  language: string;
  createdAt: Date;
  /** Source → that source's user id. */
  from: Partial<Record<SourceName, string>>;
  /** The family the user had open (source + source family id), cookless first. */
  active: Array<{ source: SourceName; familyId: string }>;
}

export interface PlannedFamily {
  id: string;
  name: string;
  feedId: string;
  legacyId: string | null;
  createdAt: Date;
  updatedAt: Date;
  home?: SourceFamily["home"];
  language?: string;
  /** Source → that source's family (household) id. */
  from: Partial<Record<SourceName, string>>;
}

export interface AccountsPlan {
  users: PlannedUser[];
  families: PlannedFamily[];
  members: SourceMember[];
}

interface Log {
  skip(source: SourceName, table: string, key: string, reason: string): void;
  note(message: string): void;
}

export function readAccounts(sources: ImportSources, now: Date): Partial<Record<SourceName, SourceAccounts>> {
  return {
    familyPlanner: sources.familyPlanner && readFamilyPlannerAccounts(sources.familyPlanner, now),
    cookless: sources.cookless && readCooklessAccounts(sources.cookless, now),
    fma: sources.fma && readFmaAccounts(sources.fma, now),
  };
}

/** Checks import-map.json against the sources: every id must exist (when that source is
 *  given) and be mapped or skipped at most once. */
export function validateMap(map: ImportMap, accounts: Partial<Record<SourceName, SourceAccounts>>, log: Log): void {
  if (!map || !Array.isArray(map.families)) throw new Error('import map: expected { "families": [ … ] }');
  if (map.skip !== undefined && !Array.isArray(map.skip)) throw new Error('import map: "skip" must be a list');
  const seen = new Set<string>();
  const check = (list: string, entry: ImportMap["families"][number], i: number) => {
    const ids = SOURCE_NAMES.filter((s) => entry[s]);
    if (ids.length === 0) throw new Error(`import map: ${list} entry ${i + 1} names no family`);
    for (const s of SOURCE_NAMES) {
      const id = entry[s];
      if (!id) continue;
      const key = `${s}:${id}`;
      if (seen.has(key)) throw new Error(`import map: ${SOURCE_LABEL[s]} ${id} is mapped twice`);
      seen.add(key);
      const acc = accounts[s];
      if (!acc) {
        log.note(`import map: ${list} entry ${i + 1} names ${SOURCE_LABEL[s]} ${id}, but no ${SOURCE_LABEL[s]} source was given`);
      } else if (!acc.families.some((f) => f.id === id)) {
        throw new Error(`import map: ${SOURCE_LABEL[s]} has no ${s === "familyPlanner" ? "family" : "household"} ${id}`);
      }
    }
  };
  map.families.forEach((entry, i) => check("families", entry, i));
  (map.skip ?? []).forEach((entry, i) => check("skip", entry, i));
}

function normEmail(email: string): string {
  return email.trim().toLowerCase();
}

const USABLE = /^(?:\$argon2(?:id|i|d)\$|pbkdf2-sha256\$)/;

/** Why a hash can't be carried over, or null when it can. */
async function unusableReason(u: SourceUser): Promise<string | null> {
  if (!u.password) return "no password";
  if (u.passwordUnusable) return u.passwordUnusable;
  if (!USABLE.test(u.password)) return "a hash format Ohana can't verify";
  for (const p of DEFAULT_PASSWORDS) {
    if (await verifyPassword(u.password, p)) return `the default password "${p}"`;
  }
  return null;
}

export async function planAccounts(
  sources: ImportSources,
  map: ImportMap,
  now: Date,
  log: Log,
): Promise<AccountsPlan> {
  const accounts = readAccounts(sources, now);
  validateMap(map, accounts, log);
  const usedIds = new Set<string>();
  const freshId = (preferred: string[]) => {
    const id = preferred.find((p) => p && !usedIds.has(p)) ?? randomUUID();
    usedIds.add(id);
    return id;
  };

  // ---- families ----
  const familyOf = (s: SourceName, id: string) => accounts[s]?.families.find((f) => f.id === id);
  const planned: PlannedFamily[] = [];
  const mapped = new Set<string>();
  const plan = (parts: Partial<Record<SourceName, SourceFamily>>) => {
    const fp = parts.familyPlanner;
    const all = SOURCE_NAMES.map((s) => parts[s]).filter((f): f is SourceFamily => !!f);
    for (const f of all) mapped.add(`${f.source}:${f.id}`);
    const createdAt = fp?.createdAt ?? new Date(Math.min(...all.map((f) => f.createdAt.getTime())));
    planned.push({
      id: freshId(SOURCE_NAMES.map((s) => parts[s]?.id ?? "")),
      name: all.map((f) => f.name.trim()).find((n) => n) ?? "Family",
      feedId: fp?.feedId || randomToken(20),
      legacyId: fp?.legacyId ?? null,
      createdAt,
      updatedAt: fp?.updatedAt ?? createdAt,
      home: parts.fma?.home,
      language: parts.fma?.language,
      from: Object.fromEntries(all.map((f) => [f.source, f.id])),
    });
  };
  // Skipped families are never planned: their rows are reported as "its family isn't imported".
  for (const entry of map.skip ?? []) {
    for (const s of SOURCE_NAMES) if (entry[s]) mapped.add(`${s}:${entry[s]}`);
  }
  for (const entry of map.families) {
    const parts: Partial<Record<SourceName, SourceFamily>> = {};
    for (const s of SOURCE_NAMES) {
      const f = entry[s] ? familyOf(s, entry[s]!) : undefined;
      if (f) parts[s] = f;
    }
    if (Object.keys(parts).length > 0) plan(parts);
  }
  for (const s of SOURCE_NAMES) {
    for (const f of accounts[s]?.families ?? []) {
      if (!mapped.has(`${s}:${f.id}`)) plan({ [s]: f });
    }
  }

  // ---- users ----
  const groups = new Map<string, SourceUser[]>();
  for (const s of SOURCE_NAMES) {
    for (const u of accounts[s]?.users ?? []) {
      const email = normEmail(u.email);
      if (!email) {
        log.skip(s, "users", u.id, "no email");
        continue;
      }
      if (!u.active) {
        log.skip(s, "users", email, "deactivated");
        continue;
      }
      groups.set(email, [...(groups.get(email) ?? []), u]);
    }
  }
  const plannedUsers: PlannedUser[] = [];
  for (const [email, group] of groups) {
    const by = (s: SourceName) => group.find((u) => u.source === s);
    let password = "";
    let passwordFrom: SourceName | null = null;
    for (const s of SOURCE_NAMES) {
      const u = by(s);
      if (!u) continue;
      const reason = await unusableReason(u);
      if (reason === null) {
        password = u.password;
        passwordFrom = s;
        break;
      }
      if (reason !== "no password") log.skip(s, "users", email, `password not carried over: ${reason}`);
    }
    plannedUsers.push({
      id: freshId(SOURCE_NAMES.map((s) => by(s)?.id ?? "")),
      email,
      name: SOURCE_NAMES.map((s) => by(s)?.name.trim() ?? "").find((n) => n) ?? "",
      password,
      passwordFrom,
      isAdmin: group.some((u) => u.isAdmin),
      language: (["cookless", "fma"] as const).map((s) => by(s)?.language).find((l) => l === "de" || l === "en") ?? "en",
      createdAt: new Date(Math.min(...group.map((u) => u.createdAt.getTime()))),
      from: Object.fromEntries(group.map((u) => [u.source, u.id])),
      active: (["cookless", "fma"] as const)
        .map((s) => ({ source: s as SourceName, familyId: by(s)?.activeFamilyId ?? "" }))
        .filter((a) => a.familyId),
    });
  }

  const members = SOURCE_NAMES.flatMap((s) => accounts[s]?.members ?? []);
  return { users: plannedUsers, families: planned, members };
}

/** Writes the planned families, users and memberships and fills ctx.userIds / familyIds.
 *  `force`: an account whose email exists in Ohana already is kept as it is (password, name)
 *  and only gets the memberships. */
export function writeAccounts(ctx: ImportContext, plan: AccountsPlan): void {
  const { db } = ctx;

  const clash = db
    .select({ id: families.id })
    .from(families)
    .where(inArray(families.id, plan.families.map((f) => f.id)))
    .all();
  if (clash.length > 0) {
    throw new ImportRefused(
      `Ohana has the families ${clash.map((c) => c.id).join(", ")} already: this data was imported before`,
    );
  }

  for (const f of plan.families) {
    db.insert(families)
      .values({
        id: f.id,
        name: f.name,
        feedId: f.feedId,
        legacyId: f.legacyId,
        homeAddress: f.home?.address || null,
        homeLat: f.home?.lat ?? null,
        homeLng: f.home?.lng ?? null,
        createdAt: f.createdAt,
        updatedAt: f.updatedAt,
      })
      .run();
    for (const s of SOURCE_NAMES) {
      const sid = f.from[s];
      if (sid) ctx.familyIds[s].set(sid, f.id);
    }
    if (f.from.familyPlanner) ctx.calendarFamilies.add(f.id);
  }

  const existing = new Map(
    db
      .select({ id: users.id, email: users.email })
      .from(users)
      .all()
      .map((u) => [u.email, u.id]),
  );
  const userEmail = new Map<string, string>();
  const idByEmail = new Map<string, string>();
  for (const u of plan.users) {
    const existingId = existing.get(u.email);
    const id = existingId ?? u.id;
    if (!existingId) {
      db.insert(users)
        .values({
          id,
          email: u.email,
          name: u.name,
          password: u.password,
          isAdmin: u.isAdmin,
          preferredLanguage: u.language,
          lastFamilyId: null, // set below, once the memberships exist
          // With a password: a passkey is offered at the first sign-in (passkeys don't move).
          onboardingStep: u.password ? "ADD_PASSKEY" : "SET_CREDENTIALS",
          createdAt: u.createdAt,
        })
        .run();
    }
    for (const s of SOURCE_NAMES) {
      const sid = u.from[s];
      if (sid) ctx.userIds[s].set(sid, id);
    }
    userEmail.set(id, u.email);
    idByEmail.set(u.email, id);
    ctx.report.users.push({
      email: u.email,
      id,
      from: SOURCE_NAMES.filter((s) => u.from[s]),
      passwordFrom: existingId ? null : u.passwordFrom,
      isAdmin: u.isAdmin,
      needsSetupLink: !existingId && !u.password,
      ...(existingId ? { existing: true } : {}),
    });
  }

  // Members: editor wins over viewer; joined at the earliest of the sources.
  const combined = new Map<string, { familyId: string; userId: string; role: "editor" | "viewer"; joinedAt: Date }>();
  for (const m of plan.members) {
    const familyId = ctx.familyIds[m.source].get(m.familyId);
    const userId = ctx.userIds[m.source].get(m.userId);
    if (!familyId || !userId) {
      ctx.skip(m.source, "members", `${m.familyId}/${m.userId}`, userId ? "its family isn't imported" : "its user isn't imported");
      continue;
    }
    const key = `${familyId}|${userId}`;
    const prev = combined.get(key);
    if (!prev) combined.set(key, { familyId, userId, role: m.role, joinedAt: m.joinedAt });
    else {
      if (m.role === "editor") prev.role = "editor";
      if (m.joinedAt < prev.joinedAt) prev.joinedAt = m.joinedAt;
    }
  }
  for (const m of combined.values()) db.insert(familyMembers).values(m).run();

  // The family the user had open, if they're a member of it.
  for (const u of plan.users) {
    if (existing.has(u.email)) continue;
    const id = idByEmail.get(u.email)!;
    const last = u.active
      .map((a) => ctx.familyIds[a.source].get(a.familyId))
      .find((f) => f && combined.has(`${f}|${id}`));
    if (last) db.update(users).set({ lastFamilyId: last }).where(eq(users.id, id)).run();
  }

  for (const f of plan.families) {
    const ms = [...combined.values()].filter((m) => m.familyId === f.id);
    ctx.report.families.push({
      id: f.id,
      name: f.name,
      from: f.from,
      members: ms.map((m) => ({ email: userEmail.get(m.userId) ?? m.userId, role: m.role })),
    });
    if (ms.length === 0) ctx.note(`family "${f.name}" (${f.id}) has no members: add them in Admin → Families`);
    else if (!ms.some((m) => m.role === "editor")) ctx.note(`family "${f.name}" (${f.id}) has no editor`);
  }
}
