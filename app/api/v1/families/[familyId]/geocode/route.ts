import { handle } from "@/lib/auth/route";
import { requireFamilyApi } from "@/lib/families/api";
import { suggestLocations } from "@/lib/appointments/geocoding";

export const dynamic = "force-dynamic";

/** Place autocomplete via Photon (search locations, the family's home address). */
export async function GET(req: Request, { params }: { params: Promise<{ familyId: string }> }) {
  return handle(async () => {
    await requireFamilyApi(req, (await params).familyId);
    const q = new URL(req.url).searchParams.get("q")?.trim() ?? "";
    return q ? suggestLocations(q) : [];
  });
}
