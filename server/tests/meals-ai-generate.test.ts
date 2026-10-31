// Recipe generation and AI photos with the family's AI settings (cookless's lib/ai/gemini.ts
// tests, now against the OpenAI-compatible endpoint): the answer is checked (verify.ts), the
// generate page's stream, the images API (and Gemini's own generateContent), the photo of a
// stored recipe. The model is the mock AI behind a fake fetch.

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { NetOptions } from "@/lib/assistant/net";
import { familyModel } from "@/lib/assistant/routes";
import { recipes, units } from "@/lib/db/schema";
import { generateImage, generateRecipeData, isGeminiEndpoint } from "@/lib/meals/ai/generate";
import { generateRecipeImage, recipePrompt, resolveGenerated } from "@/lib/meals/ai/recipes";
import { mealsAi } from "@/lib/meals/ai/status";
import { generationStream } from "@/lib/meals/ai/stream";
import { extractJson, verifyRecipes } from "@/lib/meals/ai/verify";
import { listTags } from "@/lib/meals/queries/recipes";
import { seed } from "@/lib/meals/seed";
import { AI, type AssistantTest, assistantTest, configure, fakeFetch, KEY } from "@/lib/test/assistant";
import { MOCK_PNG } from "@/lib/test/mock-ai";
import { NOW } from "@/lib/test/factories";

const net: NetOptions = { fetch: fakeFetch, resolve: () => Promise.resolve(["93.184.216.34"]) };
const provider = { baseUrl: AI, apiKey: KEY, model: "mock-large" };

let dir: string;
let current: AssistantTest[] = [];
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "ohana-gen-"));
  process.env.MEDIA_ROOT = dir;
});
afterEach(async () => {
  delete process.env.MEDIA_ROOT;
  rmSync(dir, { recursive: true, force: true });
  await Promise.all(current.map((t) => t.stop()));
  current = [];
});

function family() {
  const t = assistantTest({ worker: false });
  current.push(t);
  seed(t.db);
  return t;
}

async function readAll(stream: ReadableStream<Uint8Array>) {
  const text = await new Response(stream).text();
  return text.trim().split("\n").map((l) => JSON.parse(l));
}

describe("the model's answer", () => {
  it("is found in Markdown, objects and plain JSON", () => {
    expect(extractJson('[{"title":"A"}]')).toEqual([{ title: "A" }]);
    expect(extractJson('Sure!\n```json\n[{"title":"A"}]\n```\nEnjoy')).toEqual([{ title: "A" }]);
    // Around the JSON: the array inside is taken.
    expect(verifyRecipes(extractJson('Here: {"recipes": [{"title":"A"}]} done')).map((r) => r.title)).toEqual(["A"]);
    expect(() => extractJson("no json here")).toThrow(/not valid JSON/);
  });

  it("keeps the valid recipes, ingredients and steps, and fixes numbers given as text", () => {
    const out = verifyRecipes({
      recipes: [
        {
          title: "Soup",
          default_servings: "4",
          prep_time_minutes: "10",
          leftover_days: 9,
          ingredients: [
            { name_en: "Carrot", quantity: "2,5", unit_abbreviation: "kg", category: "VEGGIES" },
            { name_en: "", quantity: 1 },
            { name_en: "Salt", quantity: 0 },
          ],
          manual_steps: [{ step_number: 1, instruction: "Cook" }, "nonsense"],
        },
        { description: "no title" },
        "nope",
      ],
    });
    expect(out).toHaveLength(1);
    expect(out[0]).toMatchObject({ title: "Soup", default_servings: 4, prep_time_minutes: 10, leftover_days: null });
    expect(out[0].ingredients).toEqual([
      { name_en: "Carrot", quantity: 2.5, unit_abbreviation: "kg", category: "OTHER" },
    ]);
    expect(out[0].manual_steps).toHaveLength(1);
    // One recipe as an object counts too.
    expect(verifyRecipes({ title: "Solo" }).map((r) => r.title)).toEqual(["Solo"]);
    expect(() => verifyRecipes(42)).toThrow();
  });
});

describe("generating recipes", () => {
  it("asks the family's model and resolves tags and units", async () => {
    const t = family();
    const fish = listTags(t.db, t.familyId).find((x) => x.nameEn === "Fish")!;
    const prompt = recipePrompt(t.db, t.familyId, { count: 3, tagIds: [fish.id], freeText: "cosy", language: "de" });
    expect(prompt).toContain("REQUIRED TAGS");
    expect(prompt).toContain("German");
    const list = await generateRecipeData(provider, prompt, net);
    expect(list.map((r) => r.title)).toEqual(["Mock-Rezept 1 (cosy)", "Mock-Rezept 2 (cosy)", "Mock-Rezept 3 (cosy)"]);
    // The invalid ingredient of the mock is left out.
    expect(list[0].ingredients.map((i) => i.name_en)).toEqual(["Tomato", "Mock Herb"]);
    const data = resolveGenerated(t.db, t.familyId, list[0]);
    const g = t.db.select().from(units).where(eq(units.abbreviation, "g")).get()!;
    expect(data.tag_ids).toEqual([fish.id]);
    expect(data.ingredients?.[0]).toMatchObject({ name_en: "Tomato", unit_id: g.id, quantity: 200 });
  });

  it("refuses an answer without JSON with a 502", async () => {
    await expect(generateRecipeData(provider, "Mock reply please", net)).rejects.toMatchObject({ status: 502 });
  });

  it("streams the recipes, then their photos, then done", async () => {
    const t = family();
    const events = await readAll(
      generationStream({
        db: t.db,
        familyId: t.familyId,
        input: { count: 2, tagIds: [], freeText: "", generateImages: true },
        language: "en",
        provider,
        imageModel: "mock-image",
        net,
      }),
    );
    expect(events.map((e) => e.type)).toEqual(["recipe", "recipe", "image", "image", "done"]);
    expect(events[0].data.title).toBe("Mock Recipe 1");
    const webp = Buffer.from(events[2].data.image_base64, "base64");
    expect((await sharp(webp).metadata()).format).toBe("webp");
  });

  it("makes no photos without an image model, and reports a failing model", async () => {
    const t = family();
    const plain = await readAll(
      generationStream({
        db: t.db,
        familyId: t.familyId,
        input: { count: 1, tagIds: [], freeText: "", generateImages: true },
        language: "en",
        provider,
        imageModel: "",
        net,
      }),
    );
    expect(plain.map((e) => e.type)).toEqual(["recipe", "done"]);
    const broken = await readAll(
      generationStream({
        db: t.db,
        familyId: t.familyId,
        input: { count: 1, tagIds: [], freeText: "", generateImages: false },
        language: "en",
        provider: { ...provider, baseUrl: "https://nowhere.test/v1" },
        imageModel: "",
        net,
      }),
    );
    expect(broken.map((e) => e.type)).toEqual(["error", "done"]);
  });
});

describe("AI photos", () => {
  it("come from the images API of the endpoint", async () => {
    const bytes = await generateImage(provider, "mock-image", "A soup", net);
    expect(bytes.toString("base64")).toBe(MOCK_PNG);
  });

  it("ask again without response_format when the model refuses it, and download URLs", async () => {
    const seen: unknown[] = [];
    const fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input instanceof Request ? input.url : input);
      if (url.endsWith("/images/generations")) {
        const body = JSON.parse(String(init?.body));
        seen.push(body);
        if (body.response_format) {
          return Response.json({ error: { message: "Unknown parameter: 'response_format'." } }, { status: 400 });
        }
        return Response.json({ data: [{ url: "https://cdn.test/img.png" }] });
      }
      if (url === "https://cdn.test/img.png") return new Response(Buffer.from(MOCK_PNG, "base64"));
      return new Response("no", { status: 404 });
    }) as typeof globalThis.fetch;
    const bytes = await generateImage(provider, "gpt-image-1", "A soup", { ...net, fetch });
    expect(bytes.toString("base64")).toBe(MOCK_PNG);
    expect(seen).toHaveLength(2);
  });

  it("use Gemini's generateContent for a Gemini image model on Gemini's endpoint (cookless's path)", async () => {
    const gemini = { baseUrl: "https://generativelanguage.googleapis.com/v1beta/openai", apiKey: "g-key", model: "gemini-2.5-flash" };
    expect(isGeminiEndpoint(gemini.baseUrl)).toBe(true);
    expect(isGeminiEndpoint(AI)).toBe(false);
    const calls: { url: string; key: string | null; body: any }[] = []; // eslint-disable-line @typescript-eslint/no-explicit-any
    const fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      calls.push({
        url: String(input),
        key: new Headers(init?.headers).get("x-goog-api-key"),
        body: JSON.parse(String(init?.body)),
      });
      return Response.json({ candidates: [{ content: { parts: [{ text: "here" }, { inlineData: { mimeType: "image/png", data: MOCK_PNG } }] } }] });
    }) as typeof globalThis.fetch;
    const bytes = await generateImage(gemini, "gemini-2.5-flash-image", "A soup", { ...net, fetch });
    expect(bytes.toString("base64")).toBe(MOCK_PNG);
    expect(calls[0].url).toBe("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent");
    expect(calls[0].key).toBe("g-key");
    expect(calls[0].body.generationConfig).toEqual({ responseModalities: ["Image"] });
    // No image in the answer: a 502.
    const empty = (async () => Response.json({ candidates: [{ content: { parts: [{ text: "nope" }] } }] })) as unknown as typeof globalThis.fetch;
    await expect(generateImage(gemini, "gemini-2.5-flash-image", "x", { ...net, fetch: empty })).rejects.toMatchObject({ status: 502 });
  });

  it("are stored for one of the family's recipes, replacing the old one", async () => {
    const t = family();
    t.db.insert(recipes).values({ id: "r1", familyId: t.familyId, title: "Soup", listType: "KNOWN", createdAt: NOW, updatedAt: NOW }).run();
    const prompts: string[] = [];
    const gen = async (prompt: string) => {
      prompts.push(prompt);
      return Buffer.from(MOCK_PNG, "base64");
    };
    await generateRecipeImage(t.db, t.familyId, "r1", NOW, gen);
    const first = t.db.select().from(recipes).where(eq(recipes.id, "r1")).get()!.image;
    expect(first).toMatch(/^recipes\/r1_\d+\.webp$/);
    expect(prompts[0]).toContain("Dish: Soup");
    await generateRecipeImage(t.db, t.familyId, "r1", new Date(NOW.getTime() + 1000), gen);
    expect(t.db.select().from(recipes).where(eq(recipes.id, "r1")).get()!.image).not.toBe(first);
    await expect(generateRecipeImage(t.db, "other-family", "r1", NOW, gen)).rejects.toMatchObject({ status: 404 });
    await expect(
      generateRecipeImage(t.db, t.familyId, "r1", NOW, async () => Buffer.from("not an image")),
    ).rejects.toMatchObject({ status: 502 });
  });
});

describe("the meals pages' AI", () => {
  it("is offered with the family's AI settings; photos only with an image model", async () => {
    const t = family();
    expect(mealsAi(t.db, t.familyId)).toEqual({ generate: false, photos: false });
    expect(await familyModel(t.env, t.familyId)).toBeNull();
    await configure(t);
    expect(mealsAi(t.db, t.familyId)).toEqual({ generate: true, photos: false });
    const res = await t.call("PUT", `${t.ai}/settings`, { imageModel: "  mock-image " });
    expect(res.data.imageModel).toBe("mock-image");
    expect(mealsAi(t.db, t.familyId)).toEqual({ generate: true, photos: true });
    const model = await familyModel(t.env, t.familyId);
    expect(model).toEqual({ provider: { baseUrl: AI, apiKey: KEY, model: "mock-large" }, imageModel: "mock-image" });
    // Viewers can't set it.
    expect((await t.view("PUT", `${t.ai}/settings`, { imageModel: "x" })).status).toBe(403);
    expect((await t.call("PUT", `${t.ai}/settings`, { imageModel: 5 })).status).toBe(400);
  });
});
