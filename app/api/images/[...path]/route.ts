import { db } from "@/lib/db";
import { getApiUser, getAuth } from "@/lib/auth/session";
import { serveRecipeImage } from "@/lib/meals/images/serve";

export const dynamic = "force-dynamic";

/** A recipe image, for members of the recipe's family (session cookie or API token). */
export async function GET(req: Request, { params }: { params: Promise<{ path: string[] }> }): Promise<Response> {
  const { path } = await params;
  const user = getApiUser(req) ?? (await getAuth())?.user ?? null;
  return serveRecipeImage(db, user?.id ?? null, path.join("/"));
}
