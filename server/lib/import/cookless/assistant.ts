// cookless: a household's Gemini key (plaintext in cookless's database) → the family's AI
// settings, through Gemini's OpenAI-compatible endpoint, with cookless's models
// (cookless lib/ai/config.ts): the text model for the assistant, the image model for recipe
// photos. Only for families without family-planner AI settings (those win), only when AI was
// on in cookless. The assistant may only read (`allow_writes` off) until the family decides
// otherwise; no web search.
import { eq } from "drizzle-orm";
import { aiSettings } from "@/lib/db/schema";
import { all, bool, str } from "../sqlite";
import type { ImportContext } from "../types";

export const GEMINI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta/openai/";
export const GEMINI_TEXT_MODEL = "gemini-2.5-flash";
export const GEMINI_IMAGE_MODEL = "gemini-2.5-flash-image";

export function importCooklessAi(ctx: ImportContext): void {
  const src = ctx.sources.cookless;
  if (!src) return;
  for (const h of all(src.db, "SELECT id, name, ai_enabled, gemini_api_key FROM households ORDER BY created_at")) {
    const key = str(h.gemini_api_key).trim();
    if (!key) continue;
    const label = `${str(h.id)} "${str(h.name)}"`;
    const familyId = ctx.familyIds.cookless.get(str(h.id));
    if (!familyId) {
      ctx.skip("cookless", "households.gemini_api_key", label, "its household isn't imported");
      continue;
    }
    if (!bool(h.ai_enabled)) {
      ctx.skip("cookless", "households.gemini_api_key", label, "AI was turned off in cookless: enter the key in Settings → AI if wanted");
      continue;
    }
    if (ctx.db.select({ id: aiSettings.familyId }).from(aiSettings).where(eq(aiSettings.familyId, familyId)).get()) {
      ctx.skip("cookless", "households.gemini_api_key", label, "the family has family-planner's AI settings (they win)");
      continue;
    }
    ctx.db
      .insert(aiSettings)
      .values({
        familyId,
        baseUrl: GEMINI_BASE_URL,
        model: GEMINI_TEXT_MODEL,
        apiKeyEnc: ctx.secrets.seal(key),
        searchProvider: "none",
        searchKeyEnc: "",
        allowWrites: false,
        contextWindow: 0,
        imageModel: GEMINI_IMAGE_MODEL,
        updatedAt: ctx.now,
      })
      .run();
  }
}
