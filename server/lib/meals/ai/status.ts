// Whether the meals pages offer AI: recipe generation needs the family's assistant set up
// (endpoint and model), AI photos also an image model (Settings → AI); none of it when the
// server turned the assistant off.

import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { aiSettings } from "@/lib/db/schema";
import { moduleEnabled } from "@/lib/server-info";

export function mealsAi(db: Db, familyId: string): { generate: boolean; photos: boolean } {
  // The assistant turned off on this server (DISABLED_MODULES): no AI anywhere.
  if (!moduleEnabled("assistant")) return { generate: false, photos: false };
  const row = db
    .select({ baseUrl: aiSettings.baseUrl, model: aiSettings.model, imageModel: aiSettings.imageModel })
    .from(aiSettings)
    .where(eq(aiSettings.familyId, familyId))
    .get();
  const generate = !!(row?.baseUrl && row.model);
  return { generate, photos: generate && !!row?.imageModel };
}
