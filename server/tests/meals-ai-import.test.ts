// Importing a recipe from a web page (lib/meals/ai/import.ts, POST …/meals/recipes/import):
// reading the page (JSON-LD, og:image, text), the prompt, and the route against the family API
// with the mock AI. Pages and photos come from a fake fetch; nothing touches the network.

import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createFamilyApi } from "@/lib/api/family-api";
import { handleAi } from "@/lib/assistant/routes";
import { ingredients, mealTags, recipeIngredients, recipes, recipeTags, units, users } from "@/lib/db/schema";
import { extractPage, importRecipeSchema, MAX_IMPORT_TEXT } from "@/lib/meals/ai/import";
import { buildImportPrompt } from "@/lib/meals/ai/prompt";
import { importPrompt } from "@/lib/meals/ai/recipes";
import { createMealsApp } from "@/lib/meals/app-routes";
import { resolveMediaPath } from "@/lib/meals/images/storage";
import { BASE, type AssistantTest, assistantTest, configure, fakeFetch, net } from "@/lib/test/assistant";
import { NOW } from "@/lib/test/factories";
import { MOCK_PNG } from "@/lib/test/mock-ai";

type Res = { status: number; data: any }; // eslint-disable-line @typescript-eslint/no-explicit-any

const PAGE = readFileSync(join(__dirname, "fixtures/meals/recipe-page.html"), "utf8");
const PAGE_URL = "https://kitchen.test/recipes/tomato-soup";

/** The web pages and photos of the tests; everything else is fakeFetch's (the mock AI). */
const pageFetch = ((input: string | URL | Request, init?: RequestInit) => {
  const url = new URL(input instanceof Request ? input.url : String(input));
  const html = (body: string) => Promise.resolve(new Response(body, { headers: { "content-type": "text/html; charset=utf-8" } }));
  if (url.hostname === "kitchen.test") {
    net.requests.push(url.href);
    if (url.pathname === "/recipes/tomato-soup") return html(PAGE);
    if (url.pathname === "/about") return html("<html><head><title>About us</title></head><body><p>We are a small team of cooks.</p></body></html>");
    if (url.pathname === "/images/late.jpg") {
      // The photo comes after the model answered, and the client has gone by then.
      return (async () => {
        while (!net.aiBody) await new Promise((r) => setTimeout(r, 5));
        await new Promise((r) => setTimeout(r, 30));
        cancel?.();
        return new Response(Buffer.from(MOCK_PNG, "base64"), { headers: { "content-type": "image/png" } });
      })();
    }
    if (url.pathname.startsWith("/images/")) {
      return Promise.resolve(new Response(Buffer.from(MOCK_PNG, "base64"), { headers: { "content-type": "image/png" } }));
    }
    return Promise.resolve(new Response("gone", { status: 404 }));
  }
  return fakeFetch(input, init);
}) as typeof fetch;

/** Aborts the running request (the late photo calls it). */
let cancel: (() => void) | undefined;
let dir: string;
let tests: AssistantTest[] = [];
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "ohana-import-"));
  process.env.MEDIA_ROOT = dir;
  net.requests = [];
  net.aiBody = null;
  cancel = undefined;
});
afterEach(async () => {
  delete process.env.MEDIA_ROOT;
  rmSync(dir, { recursive: true, force: true });
  await Promise.all(tests.map((t) => t.stop()));
  tests = [];
});

function setup() {
  const resolve = () => Promise.resolve(["93.184.216.34"]);
  const t = assistantTest({ worker: false, env: { net: { fetch: pageFetch, resolve } } });
  tests.push(t);
  t.db.insert(units).values([
    { id: 1, nameEn: "gram", nameDe: "Gramm", abbreviation: "g", conversionFactor: "1" },
    { id: 2, nameEn: "piece", nameDe: "Stück", abbreviation: "pc", conversionFactor: "1" },
  ]).run();
  t.db.insert(ingredients).values([{ id: 1, nameEn: "Tomato", nameDe: "Tomate", category: "PRODUCE" }]).run();
  // Two known tags instead of the defaults.
  t.db.delete(mealTags).where(eq(mealTags.familyId, t.familyId)).run();
  t.db.insert(mealTags).values([
    { id: "tag-veg", familyId: t.familyId, category: "DIETARY", nameEn: "Vegetarian", nameDe: "Vegetarisch" },
    { id: "tag-fish", familyId: t.familyId, category: "PROTEIN", nameEn: "Fish", nameDe: "Fisch" },
  ]).run();
  const handler = createFamilyApi([createMealsApp({ aiEnv: () => t.env }), handleAi(t.env)], {
    db: t.db,
    appUrl: "http://ohana.test",
    now: () => NOW,
  });
  const as = (token: string) => async (method: string, path: string, body?: unknown, signal?: AbortSignal): Promise<Res> => {
    const res = await handler(
      new Request(BASE + `/families/${t.familyId}` + path, {
        method,
        signal,
        headers: { authorization: `Bearer ${token}`, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
        body: body !== undefined ? JSON.stringify(body) : undefined,
      }),
    );
    return { status: res.status, data: await res.json() };
  };
  return { t, call: as(t.editor.token), view: as(t.viewer.token) };
}

const IMPORT = "/meals/recipes/import";

describe("reading a page", () => {
  it("takes the Recipe JSON-LD, the photo, the title and the text", () => {
    const page = extractPage(PAGE, PAGE_URL);
    expect(page.title).toBe("Grandma's Tomato Soup");
    // JSON-LD's image wins over og:image, resolved against the page.
    expect(page.imageUrl).toBe("https://kitchen.test/images/soup-large.jpg");
    const data = JSON.parse(page.structuredData);
    expect(data.recipeIngredient).toEqual(["800 g tomatoes", "1 onion", "2 cups vegetable stock"]);
    expect(data).not.toHaveProperty("review");
    expect(data).not.toHaveProperty("aggregateRating");
    expect(page.text).toContain("Simmer everything in the stock");
    expect(page.text).not.toContain("do not read me");
    expect(page.text).not.toContain("Home · Recipes");
  });

  it("falls back to og:image, twitter:image and <title>", () => {
    const noLd = PAGE.replace(/<script type="application\/ld\+json">[\s\S]*?<\/script>/, "");
    expect(extractPage(noLd, PAGE_URL)).toMatchObject({
      structuredData: "",
      imageUrl: "https://kitchen.test/images/og-soup.jpg",
      title: "Grandma's Tomato Soup",
    });
    const twitter = noLd.replace(/<meta content="\/images\/og-soup.jpg" property="og:image">/, "");
    expect(extractPage(twitter, PAGE_URL).imageUrl).toBe("https://cdn.example.org/twitter-soup.jpg");
    const bare = "<html><head><title>Plain &amp; simple</title></head><body><p>Just text.</p></body></html>";
    expect(extractPage(bare, PAGE_URL)).toEqual({ title: "Plain & simple", text: "Just text.", structuredData: "", imageUrl: null });
  });

  it("finds a Recipe at the top, in a list and skips broken JSON", () => {
    const html = (ld: string) => `<html><body><script type="application/ld+json">${ld}</script><p>x</p></body></html>`;
    expect(extractPage(html('{"@type":"Recipe","name":"A","image":"https://img.test/a.jpg"}'), PAGE_URL)).toMatchObject({
      title: "A",
      imageUrl: "https://img.test/a.jpg",
    });
    expect(JSON.parse(extractPage(html('[{"@type":"Person"},{"@type":"schema:Recipe","name":"B"}]'), PAGE_URL).structuredData).name).toBe("B");
    expect(extractPage(html("{not json"), PAGE_URL).structuredData).toBe("");
  });

  it("checks the request", () => {
    expect(importRecipeSchema.parse({ url: PAGE_URL })).toEqual({ url: PAGE_URL, text: "", title: "", imageUrl: null });
    expect(importRecipeSchema.parse({ url: PAGE_URL, imageUrl: "data:image/png;base64,xx", title: null }).imageUrl).toBeNull();
    expect(importRecipeSchema.parse({ url: PAGE_URL, text: "x".repeat(MAX_IMPORT_TEXT + 10) }).text).toHaveLength(MAX_IMPORT_TEXT);
    expect(importRecipeSchema.safeParse({ url: "ftp://kitchen.test/x" }).success).toBe(false);
    expect(importRecipeSchema.safeParse({}).error?.issues[0].message).toBe("url is required");
  });
});

describe("the prompt", () => {
  it("holds the page, the catalog and the rules in the user's language", () => {
    const page = extractPage(PAGE, PAGE_URL);
    const p = buildImportPrompt({
      language: "de",
      url: PAGE_URL,
      ...page,
      ingredients: [{ nameEn: "Tomato", nameDe: "Tomate", category: "PRODUCE" }],
      units: [{ abbreviation: "g", nameEn: "gram", nameDe: "Gramm" }],
      tags: [{ id: "t", nameEn: "Vegetarian", nameDe: "Vegetarisch", category: "DIETARY" }],
    });
    expect(p).toMatch(/^You are a professional recipe editor/);
    expect(p).toContain("OUTPUT SCHEMA");
    expect(p).toContain("- title (string, in German)");
    expect(p).toContain("exactly one recipe, written in German");
    expect(p).toContain("EXISTING INGREDIENTS");
    expect(p).toContain("  - g (gram / Gramm)");
    expect(p).toContain("Vegetarian (DIETARY)");
    expect(p).toContain(`URL: ${PAGE_URL}`);
    expect(p).toContain("Title: Grandma's Tomato Soup");
    expect(p).toContain('"recipeIngredient":["800 g tomatoes"');
    expect(p).toContain("Simmer everything in the stock for 30 minutes.");
    expect(p).toContain("answer with an empty array: []");
  });

  it("takes the family's tags and the shared catalog from the database", () => {
    const { t } = setup();
    const p = importPrompt(t.db, t.familyId, { language: "en", url: PAGE_URL, title: "", structuredData: "", text: "Some text" });
    expect(p).toContain("Vegetarian (DIETARY), Fish (PROTEIN)");
    expect(p).toContain("  - Tomato / Tomate (PRODUCE)");
    expect(p).toContain("  - pc (piece / Stück)");
    expect(p).toContain("Text:\nSome text");
    expect(p).not.toContain("Title:");
  });
});

describe("POST /meals/recipes/import", () => {
  it("fetches the page, saves the recipe TO_TRY with its photo and source", async () => {
    const { t, call } = setup();
    await configure(t);
    const res = await call("POST", IMPORT, { url: PAGE_URL });
    expect(res.status).toBe(200);
    expect(res.data).toEqual({ id: expect.any(String), title: "Grandma's Tomato Soup" });
    expect(net.requests).toContain(PAGE_URL);
    expect(net.requests).toContain("https://kitchen.test/images/soup-large.jpg");
    // The model got the page and was asked to copy, not to invent.
    expect(net.aiBody.temperature).toBe(0.2);
    expect(net.aiBody.messages[0].content).toContain("Simmer everything in the stock");

    const row = t.db.select().from(recipes).where(eq(recipes.id, res.data.id)).get()!;
    expect(row).toMatchObject({ familyId: t.familyId, listType: "TO_TRY", defaultServings: 4, prepTimeMinutes: 15, cookTimeMinutes: 30 });
    expect(row.description).toBe(`From a web page.\n\nSource: ${PAGE_URL}`);
    expect(row.image).toMatch(/^recipes\/.+\.webp$/);
    expect(existsSync(resolveMediaPath(row.image)!)).toBe(true);
    const ings = t.db.select().from(recipeIngredients).where(eq(recipeIngredients.recipeId, row.id)).all();
    expect(ings.map((i) => [i.quantity, i.unitId])).toEqual([["400", 1], ["1", 2]]);
    // "vegetarian" is on the page, "fish" isn't.
    expect(t.db.select().from(recipeTags).where(eq(recipeTags.recipeId, row.id)).all().map((r) => r.tagId)).toEqual(["tag-veg"]);
  });

  it("uses the browser's text, title and photo without fetching the page", async () => {
    const { t, call } = setup();
    await configure(t);
    t.db.update(users).set({ preferredLanguage: "de" }).where(eq(users.id, t.editor.id)).run();
    const text = "Zutaten: 400 g Tomaten, 1 Zwiebel. Zubereitung: alles 30 Minuten kochen. ".repeat(3);
    const res = await call("POST", IMPORT, {
      url: "https://elsewhere.test/rezept",
      text,
      title: "Omas Tomatensuppe",
      imageUrl: "https://kitchen.test/images/shared.png",
    });
    expect(res.status).toBe(200);
    expect(res.data.title).toBe("Omas Tomatensuppe");
    expect(net.requests).not.toContain("https://elsewhere.test/rezept");
    expect(net.requests).toContain("https://kitchen.test/images/shared.png");
    expect(net.aiBody.messages[0].content).toContain("written in German");
    const row = t.db.select().from(recipes).where(eq(recipes.id, res.data.id)).get()!;
    expect(row.description).toBe("Von einer Webseite.\n\nSource: https://elsewhere.test/rezept");
    expect(row.image).not.toBe("");
  });

  it("reads HTML the browser sent like a fetched page", async () => {
    const { t, call } = setup();
    await configure(t);
    const res = await call("POST", IMPORT, { url: "https://elsewhere.test/soup", text: PAGE });
    expect(res.status).toBe(200);
    expect(res.data.title).toBe("Grandma's Tomato Soup");
    expect(net.aiBody.messages[0].content).toContain("Structured data (schema.org JSON-LD)");
    expect(net.aiBody.messages[0].content).not.toContain("do not read me");
    // The JSON-LD photo, relative to the page's address.
    expect(net.requests).toContain("https://elsewhere.test/images/soup-large.jpg");
  });

  it("saves without a photo when the photo can't be had", async () => {
    const { t, call } = setup();
    await configure(t);
    const res = await call("POST", IMPORT, { url: PAGE_URL, imageUrl: "http://127.0.0.1/photo.png" });
    expect(res.status).toBe(200);
    expect(t.db.select().from(recipes).where(eq(recipes.id, res.data.id)).get()!.image).toBe("");
    const missing = await call("POST", IMPORT, { url: PAGE_URL, imageUrl: "https://kitchen.test/nothing.png" });
    expect(missing.status).toBe(200);
  });

  it("saves nothing when the client went away before it was done", async () => {
    const { t, call } = setup();
    await configure(t);
    const controller = new AbortController();
    cancel = () => controller.abort();
    const res = await call("POST", IMPORT, { url: PAGE_URL, imageUrl: "https://kitchen.test/images/late.jpg" }, controller.signal);
    expect(res).toEqual({ status: 400, data: { error: "The import was cancelled" } });
    expect(t.db.select().from(recipes).all()).toEqual([]);
  });

  it("answers 422 for a page without a recipe and saves nothing", async () => {
    const { t, call } = setup();
    await configure(t);
    const res = await call("POST", IMPORT, { url: "https://kitchen.test/about" });
    expect(res).toEqual({ status: 422, data: { error: "No recipe found on that page" } });
    expect(t.db.select().from(recipes).all()).toEqual([]);
  });

  it("answers 502 when the page can't be loaded", async () => {
    const { t, call } = setup();
    await configure(t);
    expect(await call("POST", IMPORT, { url: "https://kitchen.test/missing" })).toEqual({
      status: 502,
      data: { error: "The page answered 404" },
    });
  });

  it("refuses private addresses, also after a redirect", async () => {
    const { t, call } = setup();
    await configure(t);
    const local = await call("POST", IMPORT, { url: "http://127.0.0.1:3000/recipe" });
    expect(local.status).toBe(400);
    expect(local.data.error).toMatch(/Private addresses/);
    const redirect = await call("POST", IMPORT, { url: "https://redirect.test/recipe" });
    expect(redirect.status).toBe(400);
    expect(net.requests.some((u) => u.startsWith("http://169.254"))).toBe(false);
    expect(t.db.select().from(recipes).all()).toEqual([]);
  });

  it("needs a valid url, an editor and the family's AI", async () => {
    const { t, call, view } = setup();
    expect(await call("POST", IMPORT, { url: PAGE_URL })).toEqual({
      status: 400,
      data: { error: "The AI isn't set up yet (Settings → AI)" },
    });
    await configure(t);
    expect((await view("POST", IMPORT, { url: PAGE_URL })).status).toBe(403);
    expect(await call("POST", IMPORT, {})).toEqual({ status: 400, data: { error: "url is required" } });
    expect((await call("POST", IMPORT, { url: "javascript:alert(1)" })).status).toBe(400);
    expect(t.db.select().from(recipes).all()).toEqual([]);
  });

  it("is off with the assistant", async () => {
    const { t, call } = setup();
    await configure(t);
    process.env.DISABLED_MODULES = "assistant";
    try {
      expect((await call("POST", IMPORT, { url: PAGE_URL })).status).toBe(404);
    } finally {
      delete process.env.DISABLED_MODULES;
    }
  });
});
