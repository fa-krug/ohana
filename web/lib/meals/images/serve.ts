import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { recipes } from "@/lib/db/schema";
import { getRole } from "@/lib/families/roles";
import { readImage } from "./storage";

/** The response for a recipe image under MEDIA_ROOT: only members of the recipe's family
 *  get it (404 for everyone else, so an image's existence isn't revealed). Paths are unique
 *  per upload, so they can be cached for good (privately). */
export async function serveRecipeImage(db: Db, userId: string | null, relative: string): Promise<Response> {
  if (!userId) return new Response("Not signed in", { status: 401 });
  const owner = db.select({ familyId: recipes.familyId }).from(recipes).where(eq(recipes.image, relative)).get();
  if (!owner || !getRole(db, owner.familyId, userId)) return new Response("Not found", { status: 404 });
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
