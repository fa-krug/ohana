import { db } from "@/lib/db";
import { createFamilyApi } from "@/lib/api/family-api";
import { handleFamily } from "@/lib/calendar/family-routes";
import { handleCalendar } from "@/lib/calendar/vacation";
import { handleFinance } from "@/lib/finance/finance";

export const dynamic = "force-dynamic";

// family-planner's API under /api/v1/families/{id}/...: the family with its calendar, types,
// entries, notes, export / import, the public calendar.ics feed (by feed id), and the finances
// (/finance/...). Later modules add their route functions to this list.
const handler = createFamilyApi([handleFamily, handleCalendar, handleFinance], { db });

export const GET = handler;
export const POST = handler;
export const PATCH = handler;
export const PUT = handler;
export const DELETE = handler;
export const OPTIONS = handler;
