// Whether the meals pages offer AI: recipe generation needs the family's assistant set up
// (endpoint and model), AI photos also an image model (Settings → AI).

import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { aiSettings } from "@/lib/db/schema";

export function mealsAi(db: Db, familyId: string): { generate: boolean; photos: boolean } {
  const row = db
    .select({ baseUrl: aiSettings.baseUrl, model: aiSettings.model, imageModel: aiSettings.imageModel })
    .from(aiSettings)
    .where(eq(aiSettings.familyId, familyId))
    .get();
  const generate = !!(row?.baseUrl && row.model);
  return { generate, photos: generate && !!row?.imageModel };
}
