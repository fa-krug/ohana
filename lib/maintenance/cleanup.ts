import type { Db } from "@/lib/db";
import { deleteOldRateLimits } from "@/lib/auth/rate-limit";
import { deleteExpiredTokens } from "@/lib/auth/tokens";
import { deleteExpiredInvites } from "@/lib/families/invites";

/** Removes expired sessions, setup links, invites and old rate-limit windows. */
export function cleanup(db: Db, now: Date): { tokens: number; invites: number; rateLimits: number } {
  return {
    tokens: deleteExpiredTokens(db, now),
    invites: deleteExpiredInvites(db, now),
    rateLimits: deleteOldRateLimits(db, now),
  };
}
