import { asc, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { families, familyMembers, users } from "@/lib/db/schema";
import type { Role } from "@/lib/families/roles";
import { isRole } from "@/lib/families/roles";

export interface AdminFamilyDto {
  id: string;
  name: string;
  createdAt: Date;
  members: { userId: string; email: string; name: string; role: Role }[];
}

export function listAllFamilies(db: Db): AdminFamilyDto[] {
  const rows = db.select().from(families).orderBy(asc(families.name)).all();
  const members = db
    .select({
      familyId: familyMembers.familyId,
      userId: familyMembers.userId,
      email: users.email,
      name: users.name,
      role: familyMembers.role,
    })
    .from(familyMembers)
    .innerJoin(users, eq(users.id, familyMembers.userId))
    .orderBy(asc(users.email))
    .all();
  return rows.map((f) => ({
    id: f.id,
    name: f.name,
    createdAt: f.createdAt,
    members: members
      .filter((m) => m.familyId === f.id)
      .map(({ userId, email, name, role }) => ({ userId, email, name, role: isRole(role) ? role : "viewer" })),
  }));
}
