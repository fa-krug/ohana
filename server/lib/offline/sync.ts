// Replays queued offline shopping ops to their family's sync route, in order.
import { all, remove } from "./queue";
import { shoppingSyncUrl } from "./submit";

export async function drainQueue(
  fetchImpl: typeof fetch = fetch,
): Promise<{ drained: number; remaining: number }> {
  const ops = await all();
  let drained = 0;
  for (const op of ops) {
    try {
      const res = await fetchImpl(shoppingSyncUrl(op.familyId), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ kind: op.kind, ...op.payload }),
        credentials: "include",
      });
      if (!res.ok) {
        // A 4xx won't get better on replay (item gone, no longer a member): drop it.
        // Anything else (5xx, proxy trouble): stop and keep the rest for later.
        if (res.status >= 400 && res.status < 500 && res.status !== 401 && res.status !== 429) {
          await remove(op.id);
          drained += 1;
          continue;
        }
        break;
      }
      await remove(op.id);
      drained += 1;
    } catch {
      break;
    }
  }
  return { drained, remaining: ops.length - drained };
}
