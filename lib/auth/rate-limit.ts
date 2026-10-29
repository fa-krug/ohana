import { and, eq, lt, sql } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { rateLimits } from "@/lib/db/schema";
import { AuthError } from "./errors";

/** Failed sign-ins allowed per sign-in name in one window. */
export const MAX_FAILURES = 10;
export const WINDOW_MS = 15 * 60 * 1000;

function windowStart(now: Date): Date {
  return new Date(Math.floor(now.getTime() / WINDOW_MS) * WINDOW_MS);
}

/** Throws 429 when `key` already failed MAX_FAILURES times in the current window. */
export function assertNotLimited(db: Db, key: string, now: Date): void {
  const row = db
    .select({ count: rateLimits.count })
    .from(rateLimits)
    .where(and(eq(rateLimits.key, key), eq(rateLimits.windowStart, windowStart(now))))
    .get();
  if (row && row.count >= MAX_FAILURES) {
    throw new AuthError(429, "Too many failed attempts. Try again in a few minutes.");
  }
}

export function recordFailure(db: Db, key: string, now: Date): void {
  db.insert(rateLimits)
    .values({ key, windowStart: windowStart(now), count: 1 })
    .onConflictDoUpdate({
      target: [rateLimits.key, rateLimits.windowStart],
      set: { count: sql`${rateLimits.count} + 1` },
    })
    .run();
}

export function deleteOldRateLimits(db: Db, now: Date): number {
  return db.delete(rateLimits).where(lt(rateLimits.windowStart, windowStart(now))).run().changes;
}
