// Routes of the family API for the native app (apple/): /appointments/... searches, runs, results and bookings (the pages use server actions).
// Registered before the module's other routes; null for paths that aren't its own.

import type { Ctx } from "@/lib/api/family-api";

export function handleAppointmentsApp(_ctx: Ctx): Promise<Response> | null {
  return null;
}
