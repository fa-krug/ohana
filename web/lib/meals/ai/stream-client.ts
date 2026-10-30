// The generate page's side of the stream (port of cookless's lib/ai/stream-client.ts): posts
// the request and hands each NDJSON event to `onEvent` as it arrives.

import type { GeneratedRecipeData } from "./recipes";
import type { GenerateRecipesInput } from "@/lib/meals/schemas/generate";

export type { GeneratedRecipeData } from "./recipes";

export type GenStreamEvent =
  | { type: "recipe"; index: number; data: GeneratedRecipeData }
  | { type: "image"; index: number; data: { image_base64: string } }
  | { type: "image_error"; message: string }
  | { type: "error"; message: string }
  | { type: "done" };

export async function streamGenerateRecipes(
  familyId: string,
  payload: GenerateRecipesInput,
  onEvent: (event: GenStreamEvent) => void,
  signal?: AbortSignal,
): Promise<void> {
  const res = await fetch(`/api/v1/families/${encodeURIComponent(familyId)}/recipes/generate`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
    signal,
  });
  if (!res.ok) {
    const body = (await Promise.resolve().then(() => res.json()).catch(() => null)) as { message?: string } | null;
    throw new Error(body?.message || `Generation failed (${res.status})`);
  }
  const reader = res.body?.getReader();
  if (!reader) throw new Error("No response body");

  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed) onEvent(JSON.parse(trimmed) as GenStreamEvent);
    }
  }
  const tail = buffer.trim();
  if (tail) onEvent(JSON.parse(tail) as GenStreamEvent);
}
