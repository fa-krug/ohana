import { cache } from "react";
import { eq } from "drizzle-orm";
import { notFound } from "next/navigation";
import { db } from "@/lib/db";
import { families } from "@/lib/db/schema";
import { requireUser } from "@/lib/auth/session";
import { getRole } from "./roles";

/** For pages under /f/[familyId]: the signed-in user, their role and the family, or a 404.
 *  Every page calls it itself (Next renders layout and page in parallel, so a check in the
 *  layout alone doesn't stop the page from running). */
export const requireFamily = cache(async (familyId: string) => {
  const user = await requireUser();
  const role = getRole(db, familyId, user.id);
  const family = role ? db.select().from(families).where(eq(families.id, familyId)).get() : undefined;
  if (!role || !family) notFound();
  return { user, role, family };
});
