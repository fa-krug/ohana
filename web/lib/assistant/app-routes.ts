// Routes of the family API for the native app (apple/): the assistant's reads and changes the existing routes don't cover.
// Registered before the module's other routes; null for paths that aren't its own.

import type { Ctx } from "@/lib/api/family-api";

export function handleAssistantApp(_ctx: Ctx): Promise<Response> | null {
  return null;
}
