// The week ahead's routes of the family API (phase 11):
//
// GET    /digest?today=YYYY-MM-DD       the next 14 days from `today` (members) → Digest
// POST   /digest/dismiss {key, today?}  "Looks fine": hides the issue for good (editors) → 204
// DELETE /digest/dismiss/{key}          shows it again (editors) → 204

import type { Ctx } from "@/lib/api/family-api";
import { CORS, HttpError, json, readBody } from "@/lib/api/http";
import { addDays, isValidDate } from "@/lib/calendar/dates";
import { ISSUE_KINDS } from "./checks";
import { buildDigest, dismissIssue, lastDayOf, restoreIssue } from "./digest";
import { DIGEST_DAYS } from "./geo";

const MAX_KEY = 300;

const noContent = () => new Response(null, { status: 204, headers: CORS });

/** The app's day: `today` when it is a date, else the server's (UTC) day. */
function todayOf(ctx: Ctx, raw: unknown): string {
  return isValidDate(raw) ? raw : ctx.now.toISOString().slice(0, 10);
}

function cleanKey(v: unknown): string {
  if (typeof v !== "string" || !v || v.length > MAX_KEY) throw new HttpError(400, "key is required");
  const kind = v.slice(0, v.indexOf(":"));
  if (!(ISSUE_KINDS as readonly string[]).includes(kind)) throw new HttpError(400, "Unknown key");
  return v;
}

/** Routes /digest[/dismiss[/{key}]]; null for anything else. */
export function handleDigest(ctx: Ctx): Promise<Response> | null {
  const { rest, method } = ctx;
  if (rest[0] !== "digest") return null;
  if (rest.length === 1) return method === "GET" ? digest(ctx) : Promise.reject(new HttpError(405, "Method not allowed"));
  if (rest[1] !== "dismiss" || rest.length > 3) return Promise.reject(new HttpError(404, "Not found"));
  if (rest.length === 2) return method === "POST" ? dismiss(ctx) : Promise.reject(new HttpError(405, "Method not allowed"));
  return method === "DELETE" ? restore(ctx, rest[2]) : Promise.reject(new HttpError(405, "Method not allowed"));
}

async function digest(ctx: Ctx): Promise<Response> {
  const { family } = await ctx.load("view");
  return json(buildDigest(ctx.db, family.id, todayOf(ctx, ctx.url.searchParams.get("today"))));
}

async function dismiss(ctx: Ctx): Promise<Response> {
  const { family } = await ctx.load("edit");
  const body = await readBody(ctx.req);
  const key = cleanKey(body.key);
  const today = todayOf(ctx, body.today ?? ctx.url.searchParams.get("today"));
  // Kept until the last day the issue concerns; one no longer in the two weeks (the app's day
  // differs, the plans changed meanwhile) until the end of them.
  const issue = buildDigest(ctx.db, family.id, today).issues.find((i) => i.key === key);
  const day = issue ? lastDayOf(issue) : addDays(today, DIGEST_DAYS - 1);
  dismissIssue(ctx.db, family.id, key, day, ctx.principal?.id ?? null, ctx.now);
  return noContent();
}

async function restore(ctx: Ctx, key: string): Promise<Response> {
  const { family } = await ctx.load("edit");
  restoreIssue(ctx.db, family.id, key);
  return noContent();
}
