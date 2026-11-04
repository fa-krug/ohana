import type { Db } from "@/lib/db";
import { deleteOldRateLimits } from "@/lib/auth/rate-limit";
import { deleteExpiredTokens } from "@/lib/auth/tokens";
import { deleteExpiredInvites } from "@/lib/families/invites";
import { pruneDismissals } from "@/lib/digest/digest";
import { pruneFailedImports } from "@/lib/meals/ai/import-queue";
import { pruneSyncs } from "@/lib/finance/bank/queue";

/** Removes expired sessions, setup links, invites, old rate-limit windows, the week ahead's
 *  dismissals of days gone by, recipe imports that failed over a week ago and bank syncs that
 *  ended over a day ago. */
export function cleanup(
  db: Db,
  now: Date,
): { tokens: number; invites: number; rateLimits: number; dismissals: number; imports: number; bankSyncs: number } {
  return {
    tokens: deleteExpiredTokens(db, now),
    invites: deleteExpiredInvites(db, now),
    rateLimits: deleteOldRateLimits(db, now),
    dismissals: pruneDismissals(db, now),
    imports: pruneFailedImports(db, now),
    bankSyncs: pruneSyncs(db, now),
  };
}
