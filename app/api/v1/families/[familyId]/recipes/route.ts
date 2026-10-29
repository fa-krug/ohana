import { db } from "@/lib/db";
import { handle } from "@/lib/auth/route";
import { listRecipes } from "@/lib/meals/queries/recipes";
import { requireFamilyRequest } from "@/lib/meals/route-auth";

export const dynamic = "force-dynamic";

/** A page of the family's recipes: `list` (KNOWN | TO_TRY), `q`, `sort`, `locale`,
 *  `tags` (comma-separated ids), `offset`, `limit` (≤ 100). */
export async function GET(req: Request, { params }: { params: Promise<{ familyId: string }> }) {
  return handle(async () => {
    const { familyId } = await params;
    await requireFamilyRequest(req, familyId, "viewer");
    const p = new URL(req.url).searchParams;
    const tagsParam = p.get("tags");
    return listRecipes(db, familyId, {
      listType: p.get("list") ?? undefined,
      search: p.get("q") ?? undefined,
      sort: p.get("sort") ?? "name-asc",
      locale: p.get("locale") ?? "en",
      tagIds: tagsParam ? tagsParam.split(",").filter(Boolean) : undefined,
      offset: Math.max(0, parseInt(p.get("offset") ?? "0", 10) || 0),
      limit: Math.min(100, Math.max(1, parseInt(p.get("limit") ?? "20", 10) || 20)),
    });
  });
}
