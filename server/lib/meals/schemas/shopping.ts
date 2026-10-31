import { z } from "zod";

export const shoppingSyncSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("toggle"), itemId: z.string().min(1) }),
  // Idempotent: what the app sends (and the offline queue replays), so a request that
  // reached the server but whose answer was lost doesn't flip the item back on replay.
  z.object({ kind: z.literal("set"), itemId: z.string().min(1), checked: z.boolean() }),
  z.object({ kind: z.literal("uncheck-all"), itemIds: z.array(z.string().min(1)) }),
]);

export type ShoppingSyncInput = z.infer<typeof shoppingSyncSchema>;
