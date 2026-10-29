// Meals routes of the family API (/api/v1/families/{id}/meals/...), for editors. They are what
// the assistant's undo steps call (the client replays them; API tokens work too):
//   PATCH  /meals/recipes/{id}            puts a recipe back (an UpsertRecipeInput)
//   DELETE /meals/recipes/{id}            deletes a recipe
//   POST   /meals/shopping/check          {ids, checked}: ticks or unticks items
//   PATCH  /meals/shopping/items/{id}     {quantity}
//   DELETE /meals/shopping/items/{id}
//   POST   /meals/plan/restore            {restore: [snapshots], remove: [iteration ids]}
//   DELETE /meals/plan                    deletes the family's meal plan

import { eq } from "drizzle-orm";
import { z } from "zod";
import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, readBody } from "@/lib/api/http";
import { mealPlans } from "@/lib/db/schema";
import { restoreIterations } from "./meal-plan/snapshot";
import { upsertRecipeInputSchema } from "./recipes/input";
import { deleteRecipe } from "./recipes/mutations";
import { upsertRecipe } from "./recipes/upsert";
import { deleteShoppingItem, setShoppingItemQuantity, setShoppingItemsChecked } from "./shopping/items";

const checkSchema = z.object({ ids: z.array(z.string()).min(1).max(500), checked: z.boolean() });
const quantitySchema = z.object({ quantity: z.string().min(1).max(40) });

export function handleMeals(ctx: Ctx): Promise<Response> | null {
  if (ctx.rest[0] !== "meals") return null;
  const [, area, sub, id, ...more] = ctx.rest;
  if (more.length) return Promise.reject(new HttpError(404, "Not found"));
  // Ids become ":id": recipes/{id}, shopping/items/{id}.
  const parts =
    area === "recipes" && sub !== undefined
      ? ["recipes", ":id", ...(id !== undefined ? [id] : [])]
      : area === "shopping" && sub === "items" && id !== undefined
        ? ["shopping", "items", ":id"]
        : [area, sub, id].filter((p) => p !== undefined);
  const route = `${ctx.method} ${parts.join("/")}`;
  switch (route) {
    case "PATCH recipes/:id":
      return run(ctx, async (familyId) => {
        const input = upsertRecipeInputSchema.parse(await readBody(ctx.req));
        return upsertRecipe(ctx.db, familyId, sub!, input, ctx.now);
      });
    case "DELETE recipes/:id":
      return run(ctx, async (familyId) => {
        deleteRecipe(ctx.db, familyId, sub!);
        return { deleted: sub };
      });
    case "POST shopping/check":
      return run(ctx, async (familyId) => {
        const { ids, checked } = checkSchema.parse(await readBody(ctx.req));
        return { count: setShoppingItemsChecked(ctx.db, familyId, ids, checked) };
      });
    case "PATCH shopping/items/:id":
      return run(ctx, async (familyId) => {
        const { quantity } = quantitySchema.parse(await readBody(ctx.req));
        setShoppingItemQuantity(ctx.db, familyId, id!, quantity);
        return { id, quantity };
      });
    case "DELETE shopping/items/:id":
      return run(ctx, async (familyId) => {
        deleteShoppingItem(ctx.db, familyId, id!);
        return { deleted: id };
      });
    case "POST plan/restore":
      return run(ctx, async (familyId) => {
        restoreIterations(ctx.db, familyId, await readBody(ctx.req), ctx.now);
        return { ok: true };
      });
    case "DELETE plan":
      return run(ctx, async (familyId) => {
        ctx.db.delete(mealPlans).where(eq(mealPlans.familyId, familyId)).run();
        return { ok: true };
      });
  }
  return Promise.reject(new HttpError(404, "Not found"));
}

async function run(ctx: Ctx, fn: (familyId: string) => Promise<unknown>): Promise<Response> {
  const { family } = await ctx.load("edit");
  return json(await fn(family.id));
}
