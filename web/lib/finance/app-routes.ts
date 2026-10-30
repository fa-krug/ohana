// Routes of the family API for the native app (apple/): the finances' reads and changes the existing family API doesn't cover.
// Registered before the module's other routes; null for paths that aren't its own.
//
// GET /finance/shopping-links: the groceries categories and the family's shopping days, so a
// groceries transaction can link to the shopping list of its trip (what the web page gets
// server-side from lib/finance/groceries.ts shoppingLinks; viewers too).

import type { Ctx } from "@/lib/api/family-api";
import { json } from "@/lib/api/http";
import { shoppingLinks } from "./groceries";

export function handleFinanceApp(ctx: Ctx): Promise<Response> | null {
  const [module, sub, rest] = ctx.rest;
  if (module !== "finance" || sub !== "shopping-links" || rest !== undefined || ctx.method !== "GET") return null;
  return shoppingLinksRoute(ctx);
}

async function shoppingLinksRoute({ db, load }: Ctx): Promise<Response> {
  const { family } = await load("view");
  return json(await shoppingLinks(db, family.id));
}
