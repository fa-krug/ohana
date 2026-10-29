import { db } from "@/lib/db";
import { createFamilyApi } from "@/lib/api/family-api";
import { handleFamily } from "@/lib/calendar/family-routes";
import { handleCalendar } from "@/lib/calendar/vacation";
import { handleEvents } from "@/lib/calendar/events";
import { handleFinance } from "@/lib/finance/finance";
import { defaultAiEnv, handleAi } from "@/lib/assistant/routes";
import { handleMeals } from "@/lib/meals/family-routes";
import { handleAppointments } from "@/lib/appointments/family-routes";

export const dynamic = "force-dynamic";

// family-planner's API under /api/v1/families/{id}/...: the family with its calendar, types,
// entries, notes, export / import, the public calendar.ics feed (by feed id), and the finances
// (/finance/...), the timed events (/events, phase 7), the assistant (/ai/..., /agent) and the
// meals' and appointments' routes the assistant's undo uses (/meals/..., /appointments/searches/...).
// Later modules add their route functions to this list.
const handler = createFamilyApi(
  [
    handleFamily,
    handleCalendar,
    handleEvents,
    handleFinance,
    handleMeals,
    handleAppointments,
    handleAi(defaultAiEnv(db)),
  ],
  { db },
);

export const GET = handler;
export const POST = handler;
export const PATCH = handler;
export const PUT = handler;
export const DELETE = handler;
export const OPTIONS = handler;
