import { randomUUID } from "node:crypto";
import { asc, eq, sql } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { families, familyMembers, users } from "@/lib/db/schema";
import { AuthError } from "@/lib/auth/errors";
import { randomToken } from "@/lib/api/http";
import { insertPresetTypes } from "@/lib/calendar/presets";
import { seedDefaultTags } from "@/lib/meals/recipes/tags";
import { insertDefaultCategories } from "@/lib/finance/presets";
import { type Actor, type Role, isRole, requireRole } from "./roles";

export type Family = typeof families.$inferSelect;

export interface FamilyDto {
  id: string;
  name: string;
  role: Role;
  memberCount: number;
}

function cleanName(name: string): string {
  const trimmed = name.trim();
  if (!trimmed) throw new AuthError(400, "The family needs a name.");
  if (trimmed.length > 100) throw new AuthError(400, "The name is too long.");
  return trimmed;
}

/** Creates a family with the calendar's preset types for this year and the default finance
 *  categories (both named in `lang`); `editorId` (if given) becomes its first editor. */
export function createFamily(
  db: Db,
  args: { name: string; editorId?: string; lang?: string },
  now: Date,
): Family {
  const name = cleanName(args.name);
  return db.transaction((tx) => {
    const family = tx
      .insert(families)
      .values({ id: randomUUID(), name, feedId: randomToken(20), createdAt: now, updatedAt: now })
      .returning()
      .get();
    const lang = args.lang === "de" ? "de" : "en";
    insertPresetTypes(tx, family.id, lang, now.getUTCFullYear());
    insertDefaultCategories(tx, family.id, lang);
    seedDefaultTags(tx as unknown as Db, family.id); // the meal tags every family starts with
    if (args.editorId) {
      tx.insert(familyMembers)
        .values({ familyId: family.id, userId: args.editorId, role: "editor", joinedAt: now })
        .run();
      tx.update(users)
        .set({ lastFamilyId: family.id })
        .where(eq(users.id, args.editorId))
        .run();
    }
    return family;
  });
}

export function getFamily(db: Db, familyId: string): Family {
  const family = db.select().from(families).where(eq(families.id, familyId)).get();
  if (!family) throw new AuthError(404, "Family not found.");
  return family;
}

export function listFamiliesOf(db: Db, userId: string): FamilyDto[] {
  const counts = db
    .select({ familyId: familyMembers.familyId, n: sql<number>`count(*)`.as("n") })
    .from(familyMembers)
    .groupBy(familyMembers.familyId)
    .as("counts");
  return db
    .select({ id: families.id, name: families.name, role: familyMembers.role, memberCount: counts.n })
    .from(familyMembers)
    .innerJoin(families, eq(families.id, familyMembers.familyId))
    .innerJoin(counts, eq(counts.familyId, families.id))
    .where(eq(familyMembers.userId, userId))
    .orderBy(asc(families.name))
    .all()
    .map((f) => ({ ...f, role: isRole(f.role) ? f.role : "viewer" }));
}

export function renameFamily(db: Db, actor: Actor, familyId: string, name: string, now: Date): void {
  requireRole(db, actor, familyId, "editor");
  getFamily(db, familyId);
  db.update(families)
    .set({ name: cleanName(name), updatedAt: now })
    .where(eq(families.id, familyId))
    .run();
}

/** Deletes a family with everything in it. Editors may only delete a family they are the
 *  sole member of; admins any family. */
export function deleteFamily(db: Db, actor: Actor, familyId: string): void {
  requireRole(db, actor, familyId, "editor");
  getFamily(db, familyId);
  if (!actor.admin) {
    const others = db
      .select({ userId: familyMembers.userId })
      .from(familyMembers)
      .where(eq(familyMembers.familyId, familyId))
      .all()
      .filter((m) => m.userId !== actor.id);
    if (others.length > 0) {
      throw new AuthError(400, "Remove the other members first, or ask an administrator.");
    }
  }
  db.delete(families).where(eq(families.id, familyId)).run(); // cascades members, invites
}

/** The family "/" opens for the user: the last one opened, else the first by name. */
export function defaultFamilyId(db: Db, user: { id: string; lastFamilyId: string | null }): string | null {
  const mine = listFamiliesOf(db, user.id);
  if (user.lastFamilyId && mine.some((f) => f.id === user.lastFamilyId)) return user.lastFamilyId;
  return mine[0]?.id ?? null;
}

export function rememberFamily(db: Db, userId: string, familyId: string): void {
  db.update(users).set({ lastFamilyId: familyId }).where(eq(users.id, userId)).run();
}
