// Recipe generation and AI recipe photos with the family's AI settings (port of cookless's
// lib/ai/gemini.ts, which called Gemini's own API with the household's key). Text: one chat
// completion against the family's OpenAI-compatible endpoint (lib/assistant/provider.ts),
// whose answer is checked by verify.ts. Photos: the endpoint's images API
// (POST {base}/images/generations) with `ai_settings.image_model`; for Gemini's endpoint
// (generativelanguage.googleapis.com, e.g. a family moved over from cookless) and a Gemini
// image model, Gemini's native generateContent instead, as cookless did: Gemini's
// OpenAI-compatible images API serves only Imagen models, not gemini-*-image.

import { HttpError } from "@/lib/api/http";
import { type NetOptions, readLimited, safeFetch } from "@/lib/assistant/net";
import { type Provider, streamChat } from "@/lib/assistant/provider";
import { extractJson, type VerifiedRecipe, verifyRecipes } from "./verify";

export const TEXT_TIMEOUT_MS = 120_000;
export const IMAGE_TIMEOUT_MS = 90_000;
const MAX_IMAGE_RESPONSE = 30_000_000;

/** Asks the model for recipes (a prompt from prompt.ts) and returns the valid ones. The
 *  generator wants ideas (temperature 0.9), the import a faithful copy (lower). */
export async function generateRecipeData(
  p: Provider,
  prompt: string,
  net: NetOptions,
  signal?: AbortSignal,
  { temperature = 0.9 }: { temperature?: number } = {},
): Promise<VerifiedRecipe[]> {
  const sig = AbortSignal.any([AbortSignal.timeout(TEXT_TIMEOUT_MS), ...(signal ? [signal] : [])]);
  let content = "";
  try {
    for await (const ev of streamChat(p, { messages: [{ role: "user", content: prompt }], temperature }, net, sig)) {
      if (ev.type === "done") content = ev.content;
    }
  } catch (err) {
    if (err instanceof HttpError) throw err;
    throw new HttpError(502, sig.aborted ? "The AI model took too long to answer" : "The AI request failed");
  }
  let recipes: VerifiedRecipe[];
  try {
    recipes = verifyRecipes(extractJson(content));
  } catch (err) {
    throw new HttpError(502, (err as Error).message);
  }
  return recipes;
}

/** True for Google's Gemini API (its OpenAI-compatible base URL included). */
export function isGeminiEndpoint(baseUrl: string): boolean {
  try {
    return new URL(baseUrl).hostname === "generativelanguage.googleapis.com";
  } catch {
    return false;
  }
}

async function json(res: Response, what: string): Promise<Record<string, any>> { // eslint-disable-line @typescript-eslint/no-explicit-any
  const text = await readLimited(res, MAX_IMAGE_RESPONSE).catch(() => "");
  if (!res.ok) {
    let message = text.slice(0, 300);
    try {
      const data = JSON.parse(text);
      message = data?.error?.message ?? data?.message ?? message;
    } catch {
      // not JSON
    }
    throw new HttpError(502, `${what}: ${res.status} ${String(message).slice(0, 300)}`.trim());
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new HttpError(502, `${what}: no JSON answer`);
  }
}

/** A photo for the prompt (buildImagePrompt) as image bytes, made by `model`. */
export async function generateImage(
  p: Provider,
  model: string,
  prompt: string,
  net: NetOptions,
  signal?: AbortSignal,
): Promise<Buffer> {
  if (!model) throw new HttpError(400, "No image model is set (Settings → AI)");
  const init = { signal, timeoutMs: IMAGE_TIMEOUT_MS };
  if (isGeminiEndpoint(p.baseUrl) && /^(models\/)?gemini/i.test(model)) {
    // cookless's path: generateContent with an image answer.
    const name = model.replace(/^models\//, "");
    const res = await safeFetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(name)}:generateContent`,
      {
        ...init,
        method: "POST",
        headers: { "content-type": "application/json", "x-goog-api-key": p.apiKey },
        body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }], generationConfig: { responseModalities: ["Image"] } }),
      },
      net,
    );
    const data = await json(res, "Image generation failed");
    const parts: { inlineData?: { data?: string } }[] = data.candidates?.[0]?.content?.parts ?? [];
    const b64 = parts.find((x) => x?.inlineData?.data)?.inlineData?.data;
    if (!b64) throw new HttpError(502, "Image generation returned no image");
    return Buffer.from(b64, "base64");
  }
  const post = (b64: boolean) =>
    safeFetch(
      p.baseUrl.replace(/\/+$/, "") + "/images/generations",
      {
        ...init,
        method: "POST",
        headers: { "content-type": "application/json", ...(p.apiKey ? { authorization: `Bearer ${p.apiKey}` } : {}) },
        body: JSON.stringify({ model, prompt, n: 1, size: "1024x1024", ...(b64 ? { response_format: "b64_json" } : {}) }),
      },
      net,
    );
  let res = await post(true);
  if (res.status === 400) {
    // Some models (gpt-image-1) refuse response_format and answer with base64 anyway.
    const text = await readLimited(res, 4000).catch(() => "");
    if (!/response_format/i.test(text)) throw new HttpError(502, `Image generation failed: 400 ${text.slice(0, 300)}`);
    res = await post(false);
  }
  const data = await json(res, "Image generation failed");
  const first = data.data?.[0] ?? {};
  if (typeof first.b64_json === "string" && first.b64_json) return Buffer.from(first.b64_json, "base64");
  if (typeof first.url === "string" && first.url) {
    const img = await safeFetch(first.url, init, net);
    if (!img.ok) throw new HttpError(502, `Image download failed: ${img.status}`);
    return Buffer.from(await img.arrayBuffer());
  }
  throw new HttpError(502, "Image generation returned no image");
}
