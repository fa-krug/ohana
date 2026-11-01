// Meals routes of the family API (/api/v1/families/{id}/meals/...), for editors. They are what
// the assistant's undo steps call (the client replays them; API tokens work too):
//   PATCH  /meals/recipes/{id}            puts a recipe back (an UpsertRecipeInput)
//   DELETE /meals/recipes/{id}            deletes a recipe
//   POST   /meals/plan/restore            {restore: [snapshots], remove: [iteration ids]}
//   DELETE /meals/plan                    deletes the family's meal plan

import { eq } from "drizzle-orm";
import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, readBody } from "@/lib/api/http";
import { mealPlans } from "@/lib/db/schema";
import { restoreIterations } from "./meal-plan/snapshot";
import { upsertRecipeInputSchema } from "./recipes/input";
import { deleteRecipe } from "./recipes/mutations";
import { upsertRecipe } from "./recipes/upsert";

export function handleMeals(ctx: Ctx): Promise<Response> | null {
  if (ctx.rest[0] !== "meals") return null;
  const [, area, sub, id, ...more] = ctx.rest;
  if (more.length) return Promise.reject(new HttpError(404, "Not found"));
  // Ids become ":id": recipes/{id}.
  const parts =
    area === "recipes" && sub !== undefined
      ? ["recipes", ":id", ...(id !== undefined ? [id] : [])]
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
