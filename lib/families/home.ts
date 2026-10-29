import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { families } from "@/lib/db/schema";
import { type Actor, requireRole } from "./roles";
import { z } from "zod";

export const homeAddressSchema = z.object({
  address: z.string().trim().max(300),
  lat: z.coerce.number().min(-90).max(90).nullable(),
  lng: z.coerce.number().min(-180).max(180).nullable(),
});
export type HomeAddressInput = z.infer<typeof homeAddressSchema>;

/** Sets (or, with an empty address, clears) the family's home address. */
export function setHomeAddress(db: Db, actor: Actor, familyId: string, input: HomeAddressInput, now: Date): void {
  requireRole(db, actor, familyId, "editor");
  const clear = !input.address || input.lat === null || input.lng === null;
  db.update(families)
    .set({
      homeAddress: clear ? null : input.address,
      homeLat: clear ? null : input.lat,
      homeLng: clear ? null : input.lng,
      updatedAt: now,
    })
    .where(eq(families.id, familyId))
    .run();
}
