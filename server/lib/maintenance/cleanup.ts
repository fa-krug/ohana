import type { Db } from "@/lib/db";
import { deleteOldRateLimits } from "@/lib/auth/rate-limit";
import { deleteExpiredTokens } from "@/lib/auth/tokens";
import { deleteExpiredInvites } from "@/lib/families/invites";
import { pruneDismissals } from "@/lib/digest/digest";
import { pruneFailedImports } from "@/lib/meals/ai/import-queue";
import { pruneMissingDocuments } from "@/lib/knowledge/documents";
import { pruneScans } from "@/lib/knowledge/scan-files";
import { moduleEnabled } from "@/lib/server-info";
import { pruneSyncs } from "@/lib/finance/bank/queue";

/** Removes expired sessions, setup links, invites, old rate-limit windows, the week ahead's
 *  dismissals of days gone by, recipe imports that failed over a week ago, bank syncs that
 *  ended over a day ago, knowledge documents whose file has been gone for 30 days (not
 *  while the module is off: its data stays) and the knowledge base's page scans (their pictures
 *  too) older than 7 days (always: they are only on their way to the AI). */
export function cleanup(
  db: Db,
  now: Date,
): {
  tokens: number;
  invites: number;
  rateLimits: number;
  dismissals: number;
  imports: number;
  bankSyncs: number;
  documents: number;
  scans: number;
} {
  return {
    tokens: deleteExpiredTokens(db, now),
    invites: deleteExpiredInvites(db, now),
    rateLimits: deleteOldRateLimits(db, now),
    dismissals: pruneDismissals(db, now),
    imports: pruneFailedImports(db, now),
    bankSyncs: pruneSyncs(db, now),
    documents: moduleEnabled("knowledge") ? pruneMissingDocuments(db, now) : 0,
    scans: pruneScans(db, now),
  };
}
