import { and, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { apptProfileCache as profileCache } from "@/lib/db/schema";

// The profile funnel is a Doctolib-only concept, so every cache row is scoped to this
// source. The column exists because profile_cache's primary key is (source, provider_slug).
const SOURCE = "doctolib";

const DAY_MS = 24 * 60 * 60 * 1000;

/** Profile-cache lifetime; profiles (motives/agendas/places) are near-static. */
export const PROFILE_CACHE_TTL_MS =
  Math.max(0, Number(process.env.PROFILE_CACHE_TTL_DAYS) || 7) * DAY_MS;

/**
 * Return a provider's profile payload, reusing a cached copy younger than `ttlMs`.
 * On a miss or stale entry, calls `fetch`, stores the result (upsert), and returns it.
 * Availabilities are dynamic and queried separately — they are never cached here.
 */
export async function loadProfilePayload(
  db: Db,
  slug: string,
  now: Date,
  ttlMs: number,
  fetch: (slug: string) => Promise<Record<string, unknown>>,
): Promise<Record<string, unknown>> {
  const row = db
    .select()
    .from(profileCache)
    .where(and(eq(profileCache.source, SOURCE), eq(profileCache.providerSlug, slug)))
    .get();
  if (row && now.getTime() - row.fetchedAt.getTime() < ttlMs) {
    return JSON.parse(row.payload) as Record<string, unknown>;
  }

  const payload = await fetch(slug);
  const serialized = JSON.stringify(payload);
  db.insert(profileCache)
    .values({ source: SOURCE, providerSlug: slug, payload: serialized, fetchedAt: now })
    .onConflictDoUpdate({
      target: [profileCache.source, profileCache.providerSlug],
      set: { payload: serialized, fetchedAt: now },
    })
    .run();
  return payload;
}
