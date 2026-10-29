import { handle } from "@/lib/auth/route";
import { requireFamilyApi } from "@/lib/families/api";
import { DoctolibClient } from "@/lib/appointments/doctolib/client";

export const dynamic = "force-dynamic";

/** Doctolib speciality autocomplete (proxied: the browser can't call Doctolib itself). */
export async function GET(req: Request, { params }: { params: Promise<{ familyId: string }> }) {
  return handle(async () => {
    await requireFamilyApi(req, (await params).familyId);
    const q = new URL(req.url).searchParams.get("q")?.trim() ?? "";
    if (!q) return [];
    try {
      const client = new DoctolibClient("https://www.doctolib.de/search", 0);
      return client.parseSpecialitySuggestions(await client.suggestSpecialities(q));
    } catch {
      // Doctolib blocking / outage → no suggestions, don't 500 the autocomplete box.
      return [];
    }
  });
}
