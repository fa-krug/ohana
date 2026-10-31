import { moduleEnabled, moduleOfFamilyPath } from "@/lib/server-info";
import type { Ctx } from "./family-api";
import { HttpError } from "./http";

/** First in the family API's route list: 404 for the paths of a module the server turned off. */
export function handleDisabledModules(ctx: Ctx): Promise<Response> | null {
  const m = moduleOfFamilyPath(ctx.rest);
  if (m && !moduleEnabled(m)) return Promise.reject(new HttpError(404, "This module is turned off on this server"));
  return null;
}
