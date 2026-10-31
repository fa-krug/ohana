// Routes of the family API for the native app (apple/): the recipes, tags, cook view and AI
// generation the web's meals pages do with server actions (app/actions/meals.ts). Same lib
// functions and checks: members read, editors change. Registered before the module's other
// routes; null for paths that aren't its own (the meal plan's and shopping lists' routes, and
// family-routes.ts's PATCH / DELETE /meals/recipes/{id}, which the app uses to save and delete).
//
//   GET    /meals/status                      {generate, photos, recipeCount}: the family's AI (lib/meals/ai/status.ts)
//                                              and how many recipes it has (the app's welcome while none)
//   GET    /meals/catalog                     {ingredients, units}: the shared lists
//   GET    /meals/tags                        {tags}
//   POST   /meals/tags                        {category, nameEn, nameDe} → {id}
//   PATCH  /meals/tags/{id}                   {nameEn, nameDe} → {id}
//   DELETE /meals/tags/{id}                   → {deleted}
//   POST   /meals/tags/reset                  → {tags} (the defaults again)
//   GET    /meals/recipes                     ?list&q&sort&locale&tags&offset&limit → {items, totalCount}
//   POST   /meals/recipes                     an UpsertRecipeInput → {id}
//   POST   /meals/recipes/bulk                {recipes} (the generator's picks) → {createdIds}
//   GET    /meals/recipes/{id}                {recipe, ingredients, units} (only those it uses)
//   POST   /meals/recipes/{id}/move           → {listType} (KNOWN ⇄ TO_TRY)
//   PUT    /meals/recipes/{id}/image          raw image/jpeg|png|webp bytes, or multipart "image" → {image}
//   DELETE /meals/recipes/{id}/image          → {image: ""}
//   POST   /meals/recipes/{id}/image/generate an AI photo (the family's image model) → {image}

import { and, eq, inArray } from "drizzle-orm";
import { z } from "zod";
import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, readBody } from "@/lib/api/http";
import { type AiEnv, defaultAiEnv, familyModel } from "@/lib/assistant/routes";
import { AuthError } from "@/lib/auth/errors";
import type { Db } from "@/lib/db";
import { ingredients as ingredientsTable, recipes, units as unitsTable } from "@/lib/db/schema";
import { generateImage } from "./ai/generate";
import { generateRecipeImage } from "./ai/recipes";
import { mealsAi } from "./ai/status";
import { ALLOWED_UPLOAD_TYPES, MAX_UPLOAD_BYTES } from "./images/config";
import { countRecipes, getRecipe, listIngredients, listRecipes, listTags, listUnits } from "./queries/recipes";
import { bulkCreateRecipes } from "./recipes/bulk-create";
import { removeRecipeImage, setRecipeImage } from "./recipes/images";
import { upsertRecipeInputSchema } from "./recipes/input";
import { moveRecipe } from "./recipes/mutations";
import { createTag, deleteTag, resetTags, updateTag } from "./recipes/tags";
import { upsertRecipe } from "./recipes/upsert";
import { bulkCreateSchema } from "./schemas/generate";
import { moduleEnabled } from "@/lib/server-info";

const tagNames = { nameEn: z.string().trim().max(80), nameDe: z.string().trim().max(80) };
const createTagSchema = z.object({ category: z.string(), ...tagNames });
const updateTagSchema = z.object(tagNames);

export interface MealsAppOptions {
  /** The AI the photo route uses (tests pass a fake one). */
  aiEnv?: (db: Db) => AiEnv;
}

export function createMealsApp(options: MealsAppOptions = {}) {
  const aiEnv = options.aiEnv ?? defaultAiEnv;

  return function handleMealsApp(ctx: Ctx): Promise<Response> | null {
    if (ctx.rest[0] !== "meals") return null;
    const [, area, ...rest] = ctx.rest;
    const m = ctx.method;

    if (area === "status" && rest.length === 0 && m === "GET") {
      return read(ctx, (familyId) => ({ ...mealsAi(ctx.db, familyId), recipeCount: countRecipes(ctx.db, familyId) }));
    }
    if (area === "catalog" && rest.length === 0 && m === "GET") {
      return read(ctx, () => ({ ingredients: listIngredients(ctx.db), units: listUnits(ctx.db) }));
    }

    if (area === "tags") {
      const [id, ...more] = rest;
      if (more.length) return null;
      if (id === undefined) {
        if (m === "GET") return read(ctx, (familyId) => ({ tags: listTags(ctx.db, familyId) }));
        if (m === "POST") {
          return write(ctx, async (familyId) => {
            const input = createTagSchema.parse(await readBody(ctx.req));
            return createTag(ctx.db, familyId, input);
          });
        }
        return null;
      }
      if (id === "reset" && m === "POST") {
        return write(ctx, async (familyId) => {
          resetTags(ctx.db, familyId);
          return { tags: listTags(ctx.db, familyId) };
        });
      }
      if (m === "PATCH") {
        return write(ctx, async (familyId) => {
          updateTag(ctx.db, familyId, id, updateTagSchema.parse(await readBody(ctx.req)));
          return { id };
        });
      }
      if (m === "DELETE") {
        return write(ctx, async (familyId) => {
          deleteTag(ctx.db, familyId, id);
          return { deleted: id };
        });
      }
      return null;
    }

    if (area !== "recipes") return null;
    const [id, sub, action, ...more] = rest;
    if (more.length) return null;

    if (id === undefined) {
      if (m === "GET") return read(ctx, (familyId) => listRecipes(ctx.db, familyId, listOptions(ctx.url)));
      if (m === "POST") {
        return write(ctx, async (familyId) => {
          const input = upsertRecipeInputSchema.parse(await readBody(ctx.req));
          return upsertRecipe(ctx.db, familyId, null, input, ctx.now);
        });
      }
      return null;
    }
    if (id === "bulk" && sub === undefined && m === "POST") {
      return write(ctx, async (familyId) => {
        const input = bulkCreateSchema.parse(await readBody(ctx.req));
        return bulkCreateRecipes(ctx.db, familyId, input, ctx.now);
      });
    }
    if (sub === undefined) {
      // PATCH / DELETE /meals/recipes/{id} are family-routes.ts's.
      if (m === "GET") return read(ctx, (familyId) => recipeWithNames(ctx.db, familyId, id));
      return null;
    }
    if (sub === "move" && action === undefined && m === "POST") {
      return write(ctx, async (familyId) => ({ listType: moveRecipe(ctx.db, familyId, id, ctx.now) }));
    }
    if (sub === "image") {
      if (action === undefined && (m === "PUT" || m === "POST")) {
        return write(ctx, async (familyId) => {
          const bytes = await uploadedImage(ctx.req);
          try {
            await setRecipeImage(ctx.db, familyId, id, bytes, ctx.now);
          } catch (e) {
            if (e instanceof AuthError) throw e;
            throw new AuthError(400, "Invalid image file");
          }
          return { image: imageOf(ctx.db, familyId, id) };
        });
      }
      if (action === undefined && m === "DELETE") {
        return write(ctx, async (familyId) => {
          removeRecipeImage(ctx.db, familyId, id);
          return { image: "" };
        });
      }
      if (action === "generate" && m === "POST") {
        return write(ctx, async (familyId) => {
          if (!moduleEnabled("assistant")) throw new HttpError(404, "The assistant is turned off on this server");
          const env = aiEnv(ctx.db);
          const model = await familyModel(env, familyId);
          if (!model?.imageModel) throw new HttpError(400, "No image model is set (Settings → AI)");
          await generateRecipeImage(ctx.db, familyId, id, ctx.now, (prompt) =>
            generateImage(model.provider, model.imageModel, prompt, env.modelNet),
          );
          return { image: imageOf(ctx.db, familyId, id) };
        });
      }
    }
    return null;
  };
}

export const handleMealsApp = createMealsApp();

async function read(ctx: Ctx, fn: (familyId: string) => unknown): Promise<Response> {
  const { family } = await ctx.load("view");
  return json(await fn(family.id));
}

async function write(ctx: Ctx, fn: (familyId: string) => Promise<unknown>): Promise<Response> {
  const { family } = await ctx.load("edit");
  return json(await fn(family.id));
}

/** The list's query, as the web's GET /recipes reads it. */
function listOptions(url: URL) {
  const p = url.searchParams;
  const tags = p.get("tags");
  return {
    listType: p.get("list") || undefined,
    search: p.get("q") ?? undefined,
    sort: p.get("sort") ?? "name-asc",
    locale: p.get("locale") === "de" ? "de" : "en",
    tagIds: tags ? tags.split(",").filter(Boolean) : undefined,
    offset: Math.max(0, parseInt(p.get("offset") ?? "0", 10) || 0),
    limit: Math.min(100, Math.max(1, parseInt(p.get("limit") ?? "20", 10) || 20)),
  };
}

/** A recipe with the shared ingredients and units it names (the app's detail and cook view). */
function recipeWithNames(db: Db, familyId: string, id: string) {
  const recipe = getRecipe(db, familyId, id);
  if (!recipe) throw new HttpError(404, "Recipe not found");
  const ingredientIds = [...new Set(recipe.ingredients.map((i) => i.ingredientId))];
  const unitIds = [...new Set(recipe.ingredients.map((i) => i.unitId))];
  return {
    recipe,
    ingredients: ingredientIds.length
      ? db
          .select({
            id: ingredientsTable.id,
            nameEn: ingredientsTable.nameEn,
            nameDe: ingredientsTable.nameDe,
            category: ingredientsTable.category,
          })
          .from(ingredientsTable)
          .where(inArray(ingredientsTable.id, ingredientIds))
          .all()
      : [],
    units: unitIds.length
      ? db
          .select({
            id: unitsTable.id,
            nameEn: unitsTable.nameEn,
            nameDe: unitsTable.nameDe,
            abbreviation: unitsTable.abbreviation,
          })
          .from(unitsTable)
          .where(inArray(unitsTable.id, unitIds))
          .all()
      : [],
  };
}

function imageOf(db: Db, familyId: string, id: string): string {
  return (
    db
      .select({ image: recipes.image })
      .from(recipes)
      .where(and(eq(recipes.id, id), eq(recipes.familyId, familyId)))
      .get()?.image ?? ""
  );
}

/** The uploaded photo: the body itself (Content-Type image/…) or a form's "image" file, with
 *  uploadRecipeImageAction's checks. */
async function uploadedImage(req: Request): Promise<Buffer> {
  const type = (req.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  let fileType: string;
  let bytes: Buffer;
  if (type === "multipart/form-data") {
    const file = (await req.formData().catch(() => null))?.get("image");
    if (!(file instanceof File)) throw new AuthError(400, "No file provided");
    fileType = file.type;
    if (file.size > MAX_UPLOAD_BYTES) throw new AuthError(400, "File too large (max 5MB)");
    bytes = Buffer.from(await file.arrayBuffer());
  } else {
    fileType = type;
    if (!ALLOWED_UPLOAD_TYPES.has(fileType)) throw new AuthError(400, "Invalid file type");
    const length = Number(req.headers.get("content-length") ?? 0);
    if (length > MAX_UPLOAD_BYTES) throw new AuthError(400, "File too large (max 5MB)");
    bytes = Buffer.from(await req.arrayBuffer());
  }
  if (!ALLOWED_UPLOAD_TYPES.has(fileType)) throw new AuthError(400, "Invalid file type");
  if (bytes.length === 0) throw new AuthError(400, "No file provided");
  if (bytes.length > MAX_UPLOAD_BYTES) throw new AuthError(400, "File too large (max 5MB)");
  return bytes;
}
