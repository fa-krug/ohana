import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { familyMembers, familyPeople } from "@/lib/db/schema";
import { AuthError } from "@/lib/auth/errors";
import { isMemberColor, type MemberColor, pickMemberColor } from "./colors";

/** The color a new account or person of the family gets: one nobody has yet, if any. */
export function nextMemberColor(db: Pick<Db, "select">, familyId: string): MemberColor {
  const used = [
    ...db.select({ c: familyMembers.color }).from(familyMembers).where(eq(familyMembers.familyId, familyId)).all(),
    ...db.select({ c: familyPeople.color }).from(familyPeople).where(eq(familyPeople.familyId, familyId)).all(),
  ].map((r) => r.c);
  return pickMemberColor(used);
}

/** Throws unless `color` is a key of the palette. */
export function assertMemberColor(color: unknown): asserts color is MemberColor {
  if (!isMemberColor(color)) throw new AuthError(400, "Invalid color.");
}
