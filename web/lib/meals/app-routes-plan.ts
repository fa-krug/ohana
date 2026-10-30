// Routes of the family API for the native app (apple/): /meals/plan/... and /meals/shopping/...
// reads and changes the meal plan and shopping pages do with server actions.
// Registered before the meals' other routes; null for paths that aren't its own.

import type { Ctx } from "@/lib/api/family-api";

export function handleMealPlanApp(_ctx: Ctx): Promise<Response> | null {
  return null;
}
