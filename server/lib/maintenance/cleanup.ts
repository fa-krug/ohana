import type { Db } from "@/lib/db";
import { deleteOldRateLimits } from "@/lib/auth/rate-limit";
import { deleteExpiredTokens } from "@/lib/auth/tokens";
import { deleteExpiredInvites } from "@/lib/families/invites";
import { pruneDismissals } from "@/lib/digest/digest";

/** Removes expired sessions, setup links, invites, old rate-limit windows and the week ahead's
 *  dismissals of days gone by. */
export function cleanup(
  db: Db,
  now: Date,
): { tokens: number; invites: number; rateLimits: number; dismissals: number } {
  return {
    tokens: deleteExpiredTokens(db, now),
    invites: deleteExpiredInvites(db, now),
    rateLimits: deleteOldRateLimits(db, now),
    dismissals: pruneDismissals(db, now),
  };
}
