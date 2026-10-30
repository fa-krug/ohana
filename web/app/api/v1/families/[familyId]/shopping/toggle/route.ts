import { db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { handle } from "@/lib/auth/route";
import { toggleShoppingItem, setShoppingItemsChecked } from "@/lib/meals/shopping/items";
import { shoppingSyncSchema } from "@/lib/meals/schemas/shopping";
import { requireFamilyRequest } from "@/lib/meals/route-auth";

export const dynamic = "force-dynamic";

/** Ticks or unticks a shopping-list item (`{ kind: "set", itemId, checked }` → `{ checked }`),
 *  flips one (`{ kind: "toggle", itemId }` → `{ checked }`) or unticks several
 *  (`{ kind: "uncheck-all", itemIds }` → `{ count }`). The offline queue replays its ops here. */
export async function POST(req: Request, { params }: { params: Promise<{ familyId: string }> }) {
  return handle(async () => {
    const { familyId } = await params;
    await requireFamilyRequest(req, familyId, "editor");
    const body = shoppingSyncSchema.parse(await req.json().catch(() => null));
    if (body.kind === "toggle") return { checked: toggleShoppingItem(db, familyId, body.itemId) };
    if (body.kind === "set") {
      if (setShoppingItemsChecked(db, familyId, [body.itemId], body.checked) === 0) {
        throw new AuthError(404, "Item not found");
      }
      return { checked: body.checked };
    }
    return { count: setShoppingItemsChecked(db, familyId, body.itemIds, false) };
  });
}
