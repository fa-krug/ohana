import { and, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { familyMembers } from "@/lib/db/schema";
import { AuthError } from "@/lib/auth/errors";

export const ROLES = ["editor", "viewer"] as const;
export type Role = (typeof ROLES)[number];

export function isRole(x: unknown): x is Role {
  return typeof x === "string" && (ROLES as readonly string[]).includes(x);
}

/** Who acts: an administrator acting from the admin pages may manage any family. */
export interface Actor {
  id: string;
  admin?: boolean;
}

export function getRole(db: Db, familyId: string, userId: string): Role | null {
  const row = db
    .select({ role: familyMembers.role })
    .from(familyMembers)
    .where(and(eq(familyMembers.familyId, familyId), eq(familyMembers.userId, userId)))
    .get();
  return row && isRole(row.role) ? row.role : null;
}

/** The actor's role; 404 for a non-member (a family's existence isn't revealed), 403 when
 *  an editor is needed. Admins acting as admins count as editors. */
export function requireRole(db: Db, actor: Actor, familyId: string, need: Role): Role {
  if (actor.admin) return "editor";
  const role = getRole(db, familyId, actor.id);
  if (!role) throw new AuthError(404, "Family not found.");
  if (need === "editor" && role !== "editor") throw new AuthError(403, "Only editors can do this.");
  return role;
}
