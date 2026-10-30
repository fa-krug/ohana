// Routes of the family API for the native app (apple/): /overview and /household/... (members, people, invites, home address, notification channels and events).
// Registered before the module's other routes; null for paths that aren't its own.

import type { Ctx } from "@/lib/api/family-api";

export function handleFamilyApp(_ctx: Ctx): Promise<Response> | null {
  return null;
}
