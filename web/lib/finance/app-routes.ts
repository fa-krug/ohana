// Routes of the family API for the native app (apple/): the finances' reads and changes the existing family API doesn't cover.
// Registered before the module's other routes; null for paths that aren't its own.

import type { Ctx } from "@/lib/api/family-api";

export function handleFinanceApp(_ctx: Ctx): Promise<Response> | null {
  return null;
}
