// Routes of the family API for the native app (apple/): /meals/... reads and changes the pages do with server actions (plan, shopping lists, recipes, tags, cook view).
// Registered before the module's other routes; null for paths that aren't its own.

import type { Ctx } from "@/lib/api/family-api";

export function handleMealsApp(_ctx: Ctx): Promise<Response> | null {
  return null;
}
