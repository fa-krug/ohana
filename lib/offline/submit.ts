// Client helpers that POST shopping-list ops to the family's sync route, falling back
// to the offline queue when the network is unavailable.
import { enqueue } from "./queue";

export type SubmitResult = "synced" | "queued" | "error";

/** The family-scoped route the ops go to (and are replayed to). */
export function shoppingSyncUrl(familyId: string): string {
  return `/api/v1/families/${encodeURIComponent(familyId)}/shopping/toggle`;
}

/** Ticks (`checked`) or unticks an item. Sent as an idempotent "set", so replaying it
 *  after a lost answer can't undo it. */
export async function submitChecked(
  familyId: string,
  itemId: string,
  checked: boolean,
): Promise<{ result: SubmitResult; checked?: boolean }> {
  try {
    const res = await fetch(shoppingSyncUrl(familyId), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "include",
      body: JSON.stringify({ kind: "set", itemId, checked }),
    });
    if (!res.ok) return { result: "error" };
    const data = (await res.json()) as { checked: boolean };
    return { result: "synced", checked: data.checked };
  } catch {
    await enqueue({ kind: "set", familyId, payload: { itemId, checked } });
    return { result: "queued" };
  }
}

export async function submitUncheckAll(familyId: string, itemIds: string[]): Promise<SubmitResult> {
  try {
    const res = await fetch(shoppingSyncUrl(familyId), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "include",
      body: JSON.stringify({ kind: "uncheck-all", itemIds }),
    });
    if (!res.ok) return "error";
    return "synced";
  } catch {
    await enqueue({ kind: "uncheck-all", familyId, payload: { itemIds } });
    return "queued";
  }
}
