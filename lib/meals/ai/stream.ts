// The generate page's stream (cookless's POST /api/recipes/generate): NDJSON events, one per
// line — {"type":"recipe","index","data"} as soon as the model answered, then per recipe its
// photo {"type":"image","index","data":{"image_base64"}} (WebP) when an image model is set and
// photos were asked for, an {"type":"error","message"} if the model failed, and {"type":"done"}.
//
// It runs inline in the web process (not in the worker like the chats): it is one call the
// user started and watches, its recipes stream in as they come, it is cut off by its timeouts
// (TEXT_TIMEOUT_MS, IMAGE_TIMEOUT_MS per photo) and ends when the page goes away (the request's
// signal). Nothing is saved here: the user picks recipes and saves them (bulkCreateRecipes).

import type { Db } from "@/lib/db";
import type { NetOptions } from "@/lib/assistant/net";
import type { Provider } from "@/lib/assistant/provider";
import { processToWebp } from "@/lib/meals/images/storage";
import type { GenerateRecipesInput } from "@/lib/meals/schemas/generate";
import { generateImage, generateRecipeData } from "./generate";
import { imagePromptOf, recipePrompt, resolveGenerated } from "./recipes";

export function generationStream(opts: {
  db: Db;
  familyId: string;
  input: GenerateRecipesInput;
  language: string;
  provider: Provider;
  imageModel: string;
  net: NetOptions;
  signal?: AbortSignal;
}): ReadableStream<Uint8Array> {
  const { db, familyId, input } = opts;
  const prompt = recipePrompt(db, familyId, { ...input, language: opts.language });
  const encoder = new TextEncoder();
  return new ReadableStream({
    async start(controller) {
      const send = (obj: unknown) => {
        try {
          controller.enqueue(encoder.encode(JSON.stringify(obj) + "\n"));
        } catch {
          // The reader went away.
        }
      };
      try {
        const recipes = (await generateRecipeData(opts.provider, prompt, opts.net, opts.signal)).slice(0, input.count);
        const data = recipes.map((r) => resolveGenerated(db, familyId, r));
        data.forEach((d, index) => send({ type: "recipe", index, data: d }));
        if (input.generateImages && opts.imageModel) {
          for (let index = 0; index < data.length && !opts.signal?.aborted; index++) {
            try {
              const bytes = await generateImage(opts.provider, opts.imageModel, imagePromptOf(data[index]), opts.net, opts.signal);
              const webp = await processToWebp(bytes);
              send({ type: "image", index, data: { image_base64: webp.toString("base64") } });
            } catch (err) {
              // A recipe without a photo (as in cookless); the first failure is reported once.
              if (index === 0) send({ type: "image_error", message: (err as Error).message });
            }
          }
        }
      } catch (err) {
        send({ type: "error", message: (err as Error).message || "Generation failed" });
      }
      send({ type: "done" });
      try {
        controller.close();
      } catch {
        // closed already
      }
    },
  });
}
