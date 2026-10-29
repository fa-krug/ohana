import { randomUUID } from "node:crypto";
import type { Db } from "@/lib/db";
import { familyMembers, users } from "@/lib/db/schema";
import { createFamily } from "@/lib/families/manage";
import type { Role } from "@/lib/families/roles";

export const NOW = new Date("2026-11-01T12:00:00Z");

export function makeUser(
  db: Db,
  args: { email?: string; name?: string; password?: string; isAdmin?: boolean; onboardingStep?: string } = {},
) {
  return db
    .insert(users)
    .values({
      id: randomUUID(),
      email: args.email ?? `${randomUUID().slice(0, 8)}@x.test`,
      name: args.name ?? "",
      password: args.password ?? "",
      isAdmin: args.isAdmin ?? false,
      onboardingStep: args.onboardingStep ?? "COMPLETED",
      createdAt: NOW,
    })
    .returning()
    .get();
}

/** A family with an editor and optionally more members. */
export function makeFamily(db: Db, editorId: string, others: { userId: string; role: Role }[] = []) {
  const family = createFamily(db, { name: "Krug", editorId }, NOW);
  for (const m of others) {
    db.insert(familyMembers).values({ familyId: family.id, userId: m.userId, role: m.role, joinedAt: NOW }).run();
  }
  return family;
}
