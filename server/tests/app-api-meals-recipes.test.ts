// The native app's meals routes (lib/meals/app-routes.ts): recipes, tags, the catalog, photos
// and the AI status, against the family API on the in-memory database with API tokens.

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createFamilyApi } from "@/lib/api/family-api";
import { handleAi } from "@/lib/assistant/routes";
import { ingredients, mealTags, recipes, units } from "@/lib/db/schema";
import { createMealsApp } from "@/lib/meals/app-routes";
import { handleMealPlanApp } from "@/lib/meals/app-routes-plan";
import { handleMeals } from "@/lib/meals/family-routes";
import { resolveMediaPath } from "@/lib/meals/images/storage";
import { DEFAULT_TAG_COUNT } from "@/lib/meals/recipes/tag-defaults";
import { BASE, type AssistantTest, assistantTest, configure } from "@/lib/test/assistant";
import { NOW } from "@/lib/test/factories";

type Res = { status: number; data: any }; // eslint-disable-line @typescript-eslint/no-explicit-any

let dir: string;
let tests: AssistantTest[] = [];
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "ohana-app-meals-"));
  process.env.MEDIA_ROOT = dir;
});
afterEach(async () => {
  delete process.env.MEDIA_ROOT;
  rmSync(dir, { recursive: true, force: true });
  await Promise.all(tests.map((t) => t.stop()));
  tests = [];
});

function setup() {
  const t = assistantTest({ worker: false });
  tests.push(t);
  t.db.insert(units).values([
    { id: 1, nameEn: "gram", nameDe: "Gramm", abbreviation: "g", conversionFactor: "1" },
    { id: 2, nameEn: "piece", nameDe: "Stück", abbreviation: "pc", conversionFactor: "1" },
  ]).run();
  t.db.insert(ingredients).values([
    { id: 1, nameEn: "Tomato", nameDe: "Tomate", category: "PRODUCE" },
    { id: 2, nameEn: "Onion", nameDe: "Zwiebel", category: "PRODUCE" },
  ]).run();
  const handler = createFamilyApi([createMealsApp({ aiEnv: () => t.env }), handleMealPlanApp, handleMeals, handleAi(t.env)], {
    db: t.db,
    appUrl: "http://ohana.test",
    now: () => NOW,
  });
  const as =
    (token: string) =>
    async (method: string, path: string, body?: unknown, raw?: { body: BodyInit; type?: string }): Promise<Res> => {
      const headers: Record<string, string> = { authorization: `Bearer ${token}` };
      if (body !== undefined) headers["content-type"] = "application/json";
      if (raw?.type) headers["content-type"] = raw.type;
      const res = await handler(
        new Request(BASE + `/families/${t.familyId}` + path, {
          method,
          headers,
          body: raw ? raw.body : body !== undefined ? JSON.stringify(body) : undefined,
        }),
      );
      const text = await res.text();
      let data: unknown = text;
      try {
        data = JSON.parse(text);
      } catch {
        // not JSON
      }
      return { status: res.status, data };
    };
  return { t, call: as(t.editor.token), view: as(t.viewer.token) };
}

const soup = (over: Record<string, unknown> = {}) => ({
  title: "Tomato soup",
  description: "Warm",
  listType: "KNOWN",
  defaultServings: 2,
  prepTimeMinutes: 10,
  cookTimeMinutes: 20,
  leftoverDays: null,
  ingredients: [
    { ingredientId: 1, nameEn: "", nameDe: "", quantity: "400", unitId: 1, order: 0 },
    { ingredientId: null, nameEn: "Basil", nameDe: "Basilikum", quantity: "2", unitId: 2, order: 1 },
  ],
  steps: [
    {
      method: "MANUAL", stepNumber: 1, instruction: "Chop", programType: "", temperature: null, durationSeconds: null,
      speed: null, turbo: false, direction: "", weightGrams: null, ingredients: [{ recipeIngredientOrder: 0, quantity: "400" }],
    },
    {
      method: "MACHINE", stepNumber: 1, instruction: "Cook", programType: "MANUAL_COOKING", temperature: 100,
      durationSeconds: 600, speed: 1, turbo: false, direction: "LEFT", weightGrams: null, ingredients: [],
    },
  ],
  tagIds: [] as string[],
  ...over,
});

const png = () => sharp({ create: { width: 64, height: 64, channels: 3, background: "red" } }).png().toBuffer();

describe("app meals: status, catalog, tags", () => {
  it("tells whether the family has AI", async () => {
    const { t, call, view } = setup();
    expect((await call("GET", "/meals/status")).data).toEqual({ generate: false, photos: false, recipeCount: 0 });
    await configure(t, { imageModel: "mock-image" });
    expect((await view("GET", "/meals/status")).data).toEqual({ generate: true, photos: true, recipeCount: 0 });
  });

  it("counts the family's recipes of both lists (the app's welcome)", async () => {
    const { call, view } = setup();
    expect((await call("POST", "/meals/recipes", soup())).status).toBe(200);
    expect((await call("POST", "/meals/recipes", soup({ title: "Pasta", listType: "TO_TRY" }))).status).toBe(200);
    expect((await view("GET", "/meals/status")).data.recipeCount).toBe(2);
  });

  it("lists the shared ingredients and units", async () => {
    const { view } = setup();
    const res = await view("GET", "/meals/catalog");
    expect(res.status).toBe(200);
    expect(res.data.ingredients).toEqual([
      { id: 1, nameEn: "Tomato", nameDe: "Tomate", category: "PRODUCE" },
      { id: 2, nameEn: "Onion", nameDe: "Zwiebel", category: "PRODUCE" },
    ]);
    expect(res.data.units[0]).toEqual({ id: 1, nameEn: "gram", nameDe: "Gramm", abbreviation: "g" });
  });

  it("creates, renames, deletes and resets tags; viewers only read", async () => {
    const { t, call, view } = setup();
    const start = (await view("GET", "/meals/tags")).data.tags;
    expect(start).toHaveLength(DEFAULT_TAG_COUNT);
    expect(start[0]).toEqual({ id: expect.any(String), category: expect.any(String), nameEn: expect.any(String), nameDe: expect.any(String) });

    expect((await view("POST", "/meals/tags", { category: "CUISINE", nameEn: "Greek", nameDe: "Griechisch" })).status).toBe(403);
    const created = await call("POST", "/meals/tags", { category: "CUISINE", nameEn: " Greek ", nameDe: "Griechisch" });
    expect(created.status).toBe(200);
    const id = created.data.id;
    expect(t.db.select().from(mealTags).where(eq(mealTags.id, id)).get()).toMatchObject({ nameEn: "Greek", isDefault: false });
    expect((await call("POST", "/meals/tags", { category: "NOPE", nameEn: "x", nameDe: "y" })).status).toBe(422);

    expect((await call("PATCH", `/meals/tags/${id}`, { nameEn: "Hellenic", nameDe: "Hellenisch" })).data).toEqual({ id });
    expect(t.db.select().from(mealTags).where(eq(mealTags.id, id)).get()?.nameDe).toBe("Hellenisch");
    expect((await call("PATCH", `/meals/tags/${id}`, { nameEn: "", nameDe: "x" })).status).toBe(422);
    expect((await view("DELETE", `/meals/tags/${id}`)).status).toBe(403);
    expect((await call("DELETE", `/meals/tags/${id}`)).data).toEqual({ deleted: id });
    expect((await call("DELETE", `/meals/tags/${id}`)).status).toBe(404);

    await call("DELETE", `/meals/tags/${start[0].id}`);
    const reset = await call("POST", "/meals/tags/reset");
    expect(reset.data.tags).toHaveLength(DEFAULT_TAG_COUNT);
  });
});

describe("app meals: recipes", () => {
  it("creates, reads, lists, moves, saves and deletes a recipe", async () => {
    const { t, call, view } = setup();
    const italian = t.db.select().from(mealTags).where(eq(mealTags.nameEn, "Italian")).get()!;
    expect((await view("POST", "/meals/recipes", soup())).status).toBe(403);
    const created = await call("POST", "/meals/recipes", soup({ tagIds: [italian.id] }));
    expect(created.status).toBe(200);
    const id = created.data.id;

    const detail = await view("GET", `/meals/recipes/${id}`);
    expect(detail.status).toBe(200);
    expect(detail.data.recipe).toMatchObject({
      id, title: "Tomato soup", listType: "KNOWN", defaultServings: 2, prepTimeMinutes: 10, image: "",
      tags: [{ id: italian.id, category: "CUISINE", nameEn: "Italian", nameDe: "Italienisch" }],
    });
    expect(detail.data.recipe.createdAt).toBe(NOW.toISOString());
    expect(detail.data.recipe.manualSteps[0]).toMatchObject({ instruction: "Chop", ingredients: [{ quantity: "400" }] });
    expect(detail.data.recipe.machineSteps[0]).toMatchObject({ programType: "MANUAL_COOKING", temperature: 100, direction: "LEFT" });
    // Only the ingredients and units it uses; Basil was added to the shared list.
    expect(detail.data.ingredients.map((i: { nameEn: string }) => i.nameEn).sort()).toEqual(["Basil", "Tomato"]);
    expect(detail.data.units.map((u: { abbreviation: string }) => u.abbreviation).sort()).toEqual(["g", "pc"]);
    expect((await view("GET", "/meals/recipes/nope")).status).toBe(404);

    await call("POST", "/meals/recipes", soup({ title: "Pizza", listType: "TO_TRY" }));
    const known = await view("GET", "/meals/recipes?list=KNOWN&sort=name-desc&locale=de");
    expect(known.data).toMatchObject({ totalCount: 1, items: [{ id, title: "Tomato soup" }] });
    expect(known.data.items[0].tags).toHaveLength(1);
    expect((await view("GET", `/meals/recipes?tags=${italian.id}`)).data.totalCount).toBe(1);
    expect((await view("GET", "/meals/recipes?q=piz")).data.items.map((r: { title: string }) => r.title)).toEqual(["Pizza"]);
    const page = await view("GET", "/meals/recipes?limit=1&offset=1&sort=name-asc");
    expect(page.data).toMatchObject({ totalCount: 2, items: [{ title: "Tomato soup" }] });

    expect((await view("POST", `/meals/recipes/${id}/move`)).status).toBe(403);
    expect((await call("POST", `/meals/recipes/${id}/move`)).data).toEqual({ listType: "TO_TRY" });
    expect((await call("POST", `/meals/recipes/${id}/move`)).data).toEqual({ listType: "KNOWN" });

    // Saving goes through family-routes.ts's PATCH (with upsertRecipe's checks).
    const saved = await call("PATCH", `/meals/recipes/${id}`, soup({ title: "Better soup" }));
    expect(saved.data).toEqual({ id });
    expect((await call("PATCH", `/meals/recipes/${id}`, soup({ title: " " }))).status).toBe(422);
    const over = soup();
    over.steps[0].ingredients[0].quantity = "500";
    expect((await call("POST", "/meals/recipes", over)).status).toBe(422);

    expect((await call("DELETE", `/meals/recipes/${id}`)).data).toEqual({ deleted: id });
    expect((await view("GET", `/meals/recipes/${id}`)).status).toBe(404);
  });

  it("saves the generator's picks to Want to try", async () => {
    const { t, call, view } = setup();
    const body = {
      recipes: [
        {
          title: "Gen soup", description: "", defaultServings: 2, prepTimeMinutes: 5, cookTimeMinutes: null, leftoverDays: null,
          ingredients: [{ nameEn: "Tomato", nameDe: "Tomate", category: "PRODUCE", quantity: "3", unitAbbreviation: "pc", order: 0 }],
          manualSteps: [{ stepNumber: 1, instruction: "Cook" }], machineSteps: [], tagIds: [],
          imageBase64: (await png()).toString("base64"),
        },
      ],
    };
    expect((await view("POST", "/meals/recipes/bulk", body)).status).toBe(403);
    const res = await call("POST", "/meals/recipes/bulk", body);
    expect(res.status).toBe(200);
    expect(res.data.createdIds).toHaveLength(1);
    const row = t.db.select().from(recipes).where(eq(recipes.id, res.data.createdIds[0])).get()!;
    expect(row).toMatchObject({ listType: "TO_TRY", title: "Gen soup" });
    expect(row.image).toMatch(/\.webp$/);
    expect((await call("POST", "/meals/recipes/bulk", { recipes: [] })).status).toBe(400);
  });
});

describe("app meals: photos", () => {
  it("uploads raw bytes or a form, removes the photo; checks type and role", async () => {
    const { t, call, view } = setup();
    const id = (await call("POST", "/meals/recipes", soup())).data.id;
    const bytes = await png();

    expect((await view("PUT", `/meals/recipes/${id}/image`, undefined, { body: new Uint8Array(bytes), type: "image/png" })).status).toBe(403);
    const raw = await call("PUT", `/meals/recipes/${id}/image`, undefined, { body: new Uint8Array(bytes), type: "image/png" });
    expect(raw.status).toBe(200);
    expect(raw.data.image).toMatch(new RegExp(`^recipes/${id}_\\d+\\.webp$`));
    expect(resolveMediaPath(raw.data.image)).toBeTruthy();

    const form = new FormData();
    form.append("image", new File([new Uint8Array(bytes)], "x.png", { type: "image/png" }));
    const multi = await call("POST", `/meals/recipes/${id}/image`, undefined, { body: form });
    expect(multi.status).toBe(200);
    expect(t.db.select().from(recipes).where(eq(recipes.id, id)).get()?.image).toBe(multi.data.image);

    expect((await call("PUT", `/meals/recipes/${id}/image`, undefined, { body: "x", type: "image/gif" })).data).toEqual({ error: "Invalid file type" });
    expect((await call("PUT", `/meals/recipes/${id}/image`, undefined, { body: "nope", type: "image/jpeg" })).data).toEqual({ error: "Invalid image file" });
    expect((await call("PUT", `/meals/recipes/nope/image`, undefined, { body: new Uint8Array(bytes), type: "image/png" })).status).toBe(404);

    expect((await call("DELETE", `/meals/recipes/${id}/image`)).data).toEqual({ image: "" });
    expect(t.db.select().from(recipes).where(eq(recipes.id, id)).get()?.image).toBe("");
  });

  it("makes an AI photo with the family's image model", async () => {
    const { t, call, view } = setup();
    const id = (await call("POST", "/meals/recipes", soup())).data.id;
    const none = await call("POST", `/meals/recipes/${id}/image/generate`);
    expect(none).toEqual({ status: 400, data: { error: "No image model is set (Settings → AI)" } });
    await configure(t, { imageModel: "mock-image" });
    expect((await view("POST", `/meals/recipes/${id}/image/generate`)).status).toBe(403);
    const res = await call("POST", `/meals/recipes/${id}/image/generate`);
    expect(res.status).toBe(200);
    expect(res.data.image).toMatch(/\.webp$/);
  });
});

describe("app meals: other paths", () => {
  it("leaves shopping and unknown paths to the other routes", async () => {
    const { call } = setup();
    expect((await call("POST", "/meals/shopping/check", { ids: ["x"], checked: true })).data).toEqual({ count: 0 });
    expect((await call("GET", "/meals/recipes/x/y/z")).status).toBe(404);
    expect((await call("PUT", "/meals/tags")).status).toBe(404);
  });
});
