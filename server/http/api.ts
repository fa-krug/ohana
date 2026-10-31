// The JSON API under /api: what the native app (apple/) and scripts use. The route logic lives
// in lib/ (one route module per area); this file only maps paths onto it.

import { Hono, type Context } from "hono";
import { ZodError } from "zod";
import type { Db } from "@/lib/db";
import { createFamilyApi } from "@/lib/api/family-api";
import { handleDisabledModules } from "@/lib/api/disabled-modules";
import { HttpError } from "@/lib/api/http";
import { handleAdminApp } from "@/lib/admin/app-routes";
import { handleAppointments } from "@/lib/appointments/family-routes";
import { handleAppointmentsApp } from "@/lib/appointments/app-routes";
import { DoctolibClient } from "@/lib/appointments/doctolib/client";
import { suggestLocations } from "@/lib/appointments/geocoding";
import { suggestJamedaTerms } from "@/lib/appointments/jameda/terms";
import { handleAssistantApp } from "@/lib/assistant/app-routes";
import { defaultAiEnv, familyModel, handleAi } from "@/lib/assistant/routes";
import { handleAccountApp } from "@/lib/auth/app-routes";
import { AuthError } from "@/lib/auth/errors";
import { handle } from "@/lib/auth/route";
import { serializeUser } from "@/lib/auth/serialize";
import { getApiUser, getAuth } from "@/lib/auth/session";
import { deleteToken, findToken } from "@/lib/auth/tokens";
import { handleCalendarApp } from "@/lib/calendar/app-routes";
import { handleEvents } from "@/lib/calendar/events";
import { handleFamily } from "@/lib/calendar/family-routes";
import { handleCalendar } from "@/lib/calendar/vacation";
import { requireFamilyApi } from "@/lib/families/api";
import { createFamilyForUser, handleFamilyApp } from "@/lib/families/app-routes";
import { handleInvitesApp } from "@/lib/families/invite-routes";
import { listFamiliesOf } from "@/lib/families/manage";
import { handleFinanceApp } from "@/lib/finance/app-routes";
import { handleFinance } from "@/lib/finance/finance";
import { generationStream } from "@/lib/meals/ai/stream";
import { handleMealsApp } from "@/lib/meals/app-routes";
import { handleMealPlanApp } from "@/lib/meals/app-routes-plan";
import { handleMeals } from "@/lib/meals/family-routes";
import { serveRecipeImage } from "@/lib/meals/images/serve";
import { getRecipe, listIngredients, listRecipes, listUnits } from "@/lib/meals/queries/recipes";
import { requireFamilyRequest } from "@/lib/meals/route-auth";
import { generateRecipesSchema } from "@/lib/meals/schemas/generate";
import { shoppingSyncSchema } from "@/lib/meals/schemas/shopping";
import { setShoppingItemsChecked, toggleShoppingItem } from "@/lib/meals/shopping/items";
import { type ModuleName, moduleEnabled, serverInfo } from "@/lib/server-info";

const API_TOKEN_REQUIRED = "A valid API token is required (Authorization: Bearer …).";

/** The path below `prefix` as decoded parts (`/api/v1/me/tokens/x` → ["tokens", "x"]). */
function pathAfter(c: Context, prefix: string): string[] {
  const rest = c.req.path.slice(prefix.length);
  return rest.split("/").filter(Boolean).map(decodeURIComponent);
}

/** 404 `{ message }` for a module the server turned off (the separate meals / appointments routes). */
function requireModule(m: ModuleName): void {
  if (!moduleEnabled(m)) throw new AuthError(404, "This module is turned off on this server");
}

export function apiRoutes(db: Db): Hono {
  const api = new Hono();

  // ---- server ----
  api.get("/health", () => Response.json({ status: "ok" }));
  // What the app checks before it connects: version, API version, modules (public).
  api.get("/v1/server", () => Response.json(serverInfo()));

  // ---- the account (API token) ----
  api.get("/v1/me", (c) =>
    handle(async () => {
      const user = getApiUser(c.req.raw);
      if (!user) throw new AuthError(401, API_TOKEN_REQUIRED);
      return { user: serializeUser(db, user), families: listFamiliesOf(db, user.id) };
    }),
  );
  // Signs the API token out: deletes it (the native app's "Sign out").
  api.delete("/v1/me", (c) =>
    handle(async () => {
      const match = /^Bearer\s+(\S+)$/i.exec(c.req.header("authorization") ?? "");
      const found = match ? findToken(db, match[1], "api", new Date()) : null;
      if (!found) throw new AuthError(401, API_TOKEN_REQUIRED);
      deleteToken(db, found.token.id);
      return { ok: true };
    }),
  );
  api.all("/v1/me/*", (c) => handleAccountApp(db, c.req.raw, pathAfter(c, "/api/v1/me")));
  api.all("/v1/admin/*", (c) => handleAdminApp(db, c.req.raw, pathAfter(c, "/api/v1/admin")));
  api.all("/v1/invites/*", (c) => handleInvitesApp(db, c.req.raw, pathAfter(c, "/api/v1/invites")));

  // Creates a family for the API token's user (the app's "New family").
  api.post("/v1/families", (c) =>
    handle(async () => {
      const user = getApiUser(c.req.raw);
      if (!user) throw new AuthError(401, API_TOKEN_REQUIRED);
      const body = await c.req.raw.json().catch(() => {
        throw new AuthError(400, "Body must be a JSON object");
      });
      return createFamilyForUser(db, user, body, c.req.header("accept-language") ?? null, new Date());
    }),
  );

  // ---- separate family routes (before the family API's catch-all) ----
  // A page of the family's recipes: list (KNOWN | TO_TRY), q, sort, locale, tags, offset, limit (≤ 100).
  api.get("/v1/families/:familyId/recipes", (c) =>
    handle(async () => {
      requireModule("meals");
      const familyId = c.req.param("familyId");
      await requireFamilyRequest(c.req.raw, familyId, "viewer");
      const tagsParam = c.req.query("tags");
      return listRecipes(db, familyId, {
        listType: c.req.query("list") ?? undefined,
        search: c.req.query("q") ?? undefined,
        sort: c.req.query("sort") ?? "name-asc",
        locale: c.req.query("locale") ?? "en",
        tagIds: tagsParam ? tagsParam.split(",").filter(Boolean) : undefined,
        offset: Math.max(0, parseInt(c.req.query("offset") ?? "0", 10) || 0),
        limit: Math.min(100, Math.max(1, parseInt(c.req.query("limit") ?? "20", 10) || 20)),
      });
    }),
  );
  // Generates recipes with the family's AI (editors): an NDJSON stream; nothing is saved.
  api.post("/v1/families/:familyId/recipes/generate", async (c) => {
    try {
      requireModule("meals");
      requireModule("assistant");
      const familyId = c.req.param("familyId");
      const user = await requireFamilyRequest(c.req.raw, familyId, "editor");
      const input = generateRecipesSchema.parse(await c.req.raw.json().catch(() => ({})));
      const env = defaultAiEnv(db);
      const model = await familyModel(env, familyId);
      if (!model) throw new AuthError(400, "The AI isn't set up yet (Settings → AI)");
      const stream = generationStream({
        db,
        familyId,
        input,
        language: user.preferredLanguage === "de" ? "de" : "en",
        provider: model.provider,
        imageModel: model.imageModel,
        net: env.modelNet,
        signal: c.req.raw.signal,
      });
      return new Response(stream, {
        headers: { "Content-Type": "application/x-ndjson", "Cache-Control": "no-cache", "X-Accel-Buffering": "no" },
      });
    } catch (e) {
      if (e instanceof AuthError || e instanceof HttpError) return Response.json({ message: e.message }, { status: e.status });
      if (e instanceof ZodError) return Response.json({ message: e.issues[0]?.message ?? "Invalid input." }, { status: 400 });
      throw e;
    }
  });
  // One recipe, with the shared ingredient and unit lists.
  api.get("/v1/families/:familyId/recipes/:id", (c) =>
    handle(async () => {
      requireModule("meals");
      const familyId = c.req.param("familyId");
      await requireFamilyRequest(c.req.raw, familyId, "viewer");
      const recipe = getRecipe(db, familyId, c.req.param("id"));
      if (!recipe) throw new AuthError(404, "Recipe not found");
      return { recipe, ingredients: listIngredients(db), units: listUnits(db) };
    }),
  );
  // Ticks / unticks a shopping item, or unticks several (the app's offline queue replays here).
  api.post("/v1/families/:familyId/shopping/toggle", (c) =>
    handle(async () => {
      requireModule("meals");
      const familyId = c.req.param("familyId");
      await requireFamilyRequest(c.req.raw, familyId, "editor");
      const body = shoppingSyncSchema.parse(await c.req.raw.json().catch(() => null));
      if (body.kind === "toggle") return { checked: toggleShoppingItem(db, familyId, body.itemId) };
      if (body.kind === "set") {
        if (setShoppingItemsChecked(db, familyId, [body.itemId], body.checked) === 0) {
          throw new AuthError(404, "Item not found");
        }
        return { checked: body.checked };
      }
      return { count: setShoppingItemsChecked(db, familyId, body.itemIds, false) };
    }),
  );
  // Place autocomplete via Photon (search locations, the family's home address).
  api.get("/v1/families/:familyId/geocode", (c) =>
    handle(async () => {
      await requireFamilyApi(c.req.raw, c.req.param("familyId"));
      const q = c.req.query("q")?.trim() ?? "";
      return q ? suggestLocations(q) : [];
    }),
  );
  // jameda term autocomplete, from the bundled dataset.
  api.get("/v1/families/:familyId/appointments/jameda-terms", (c) =>
    handle(async () => {
      requireModule("appointments");
      await requireFamilyApi(c.req.raw, c.req.param("familyId"));
      const q = c.req.query("q")?.trim() ?? "";
      return q ? suggestJamedaTerms(q) : [];
    }),
  );
  // Doctolib speciality autocomplete (proxied).
  api.get("/v1/families/:familyId/appointments/doctolib-specialities", (c) =>
    handle(async () => {
      requireModule("appointments");
      await requireFamilyApi(c.req.raw, c.req.param("familyId"));
      const q = c.req.query("q")?.trim() ?? "";
      if (!q) return [];
      try {
        const client = new DoctolibClient("https://www.doctolib.de/search", 0);
        return client.parseSpecialitySuggestions(await client.suggestSpecialities(q));
      } catch {
        // Doctolib blocking / outage → no suggestions, don't fail the autocomplete box.
        return [];
      }
    }),
  );

  // ---- the family API (family-planner's handler): /api/v1/families/{id}/... ----
  // Every module adds its route function; the app's `*App` routes come before the module's own
  // routes, which answer 404 for any other path under their prefix. Modules the server turned
  // off answer 404 first.
  const familyApi = createFamilyApi(
    [
      handleDisabledModules,
      handleFamilyApp,
      handleCalendarApp,
      handleFamily,
      handleCalendar,
      handleEvents,
      handleFinanceApp,
      handleFinance,
      handleMealsApp,
      handleMealPlanApp,
      handleMeals,
      handleAppointmentsApp,
      handleAppointments,
      handleAssistantApp,
      handleAi(defaultAiEnv(db)),
    ],
    { db },
  );
  api.all("/v1/families/:familyId", (c) => familyApi(c.req.raw));
  api.all("/v1/families/:familyId/*", (c) => familyApi(c.req.raw));

  // ---- recipe photos, for members of the recipe's family (session cookie or API token) ----
  api.get("/images/*", async (c) => {
    const user = getApiUser(c.req.raw) ?? (await getAuth())?.user ?? null;
    return serveRecipeImage(db, user?.id ?? null, pathAfter(c, "/api/images").join("/"));
  });

  return api;
}
