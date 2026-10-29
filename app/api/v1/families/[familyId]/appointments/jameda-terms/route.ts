import { handle } from "@/lib/auth/route";
import { requireFamilyApi } from "@/lib/families/api";
import { suggestJamedaTerms } from "@/lib/appointments/jameda/terms";

export const dynamic = "force-dynamic";

/** jameda term autocomplete (Fachgebiet / Leistung / Erkrankung), from the bundled dataset. */
export async function GET(req: Request, { params }: { params: Promise<{ familyId: string }> }) {
  return handle(async () => {
    await requireFamilyApi(req, (await params).familyId);
    const q = new URL(req.url).searchParams.get("q")?.trim() ?? "";
    return q ? suggestJamedaTerms(q) : [];
  });
}
