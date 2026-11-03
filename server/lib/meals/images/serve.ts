import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { familyMembers, familyPeople, recipes } from "@/lib/db/schema";
import { getRole } from "@/lib/families/roles";
import { readImage } from "./storage";

/** The family an image under MEDIA_ROOT belongs to: a recipe's photo, a member's or a
 *  person's photo or its original (lib/families/photos.ts); null when nothing refers to it. */
function ownerFamily(db: Db, relative: string): string | null {
  if (!relative) return null;
  return (
    db.select({ familyId: recipes.familyId }).from(recipes).where(eq(recipes.image, relative)).get()?.familyId ??
    db.select({ familyId: familyMembers.familyId }).from(familyMembers).where(eq(familyMembers.photo, relative)).get()
      ?.familyId ??
    db.select({ familyId: familyPeople.familyId }).from(familyPeople).where(eq(familyPeople.photo, relative)).get()
      ?.familyId ??
    db
      .select({ familyId: familyMembers.familyId })
      .from(familyMembers)
      .where(eq(familyMembers.photoOriginal, relative))
      .get()?.familyId ??
    db
      .select({ familyId: familyPeople.familyId })
      .from(familyPeople)
      .where(eq(familyPeople.photoOriginal, relative))
      .get()?.familyId ??
    null
  );
}

/** The response for an image under MEDIA_ROOT (a recipe's or a member's photo or original): only members
 *  of its family get it (404 for everyone else, so an image's existence isn't revealed). Paths
 *  are unique per upload, so they can be cached for good (privately). */
export async function serveImage(db: Db, userId: string | null, relative: string): Promise<Response> {
  if (!userId) return new Response("Not signed in", { status: 401 });
  const familyId = ownerFamily(db, relative);
  if (!familyId || !getRole(db, familyId, userId)) return new Response("Not found", { status: 404 });
  const bytes = await readImage(relative);
  if (!bytes) return new Response("Not found", { status: 404 });
  return new Response(new Uint8Array(bytes), {
    status: 200,
    headers: {
      "Content-Type": "image/webp",
      "Cache-Control": "private, max-age=31536000, immutable",
    },
  });
}
