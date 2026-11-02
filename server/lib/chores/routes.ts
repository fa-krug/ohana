// Chores of the family API (/api/v1/families/{id}/chores…). Members read, editors change; a
// viewer may tick off the chores assigned to them, and every member subscribes themselves to a
// chore's notification. `today` (YYYY-MM-DD, default: the server's day) is the day `next` and
// the overdue chores are worked out for.
//
// GET    /chores?today=                    {chores, people, canEdit}
// GET    /chores/agenda?from=&to=&today=   {days: [{date, items}], overdue} (at most 62 days)
// POST   /chores?today=                    ChoreInput (+ id: a chore put back) → 201 {chore}
// GET    /chores/{id}?today=               {chore}
// PATCH  /chores/{id}?today=               the fields to change → {chore}
// DELETE /chores/{id}                      {deleted: id}
// POST   /chores/{id}/done?today=          {done, day?} → {chore} (day: a repeating chore's occurrence)
// POST   /chores/{id}/subscribe?today=     {subscribed} → {chore} (the caller)

import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, readBody } from "@/lib/api/http";
import { isValidDate } from "@/lib/calendar/dates";
import {
  choreAgenda,
  chorePeople,
  createChore,
  deleteChore,
  getChore,
  getChoreRow,
  listChores,
  setChoreDone,
  setChoreSubscribed,
  updateChore,
} from "./chores";

/** Routes /families/{id}/chores[/agenda | /{choreId}[/done | /subscribe]]; null for anything else. */
export function handleChores(ctx: Ctx): Promise<Response> | null {
  if (ctx.rest[0] !== "chores") return null;
  const [, id, sub, ...more] = ctx.rest;
  const { method } = ctx;
  if (more.length || (sub !== undefined && sub !== "done" && sub !== "subscribe")) {
    return Promise.reject(new HttpError(404, "Not found"));
  }
  if (sub === "done") return method === "POST" ? doneRoute(ctx, id) : notAllowed();
  if (sub === "subscribe") return method === "POST" ? subscribeRoute(ctx, id) : notAllowed();
  if (id === undefined) {
    if (method === "GET") return listRoute(ctx);
    if (method === "POST") return createRoute(ctx);
    return notAllowed();
  }
  if (id === "agenda") return method === "GET" ? agendaRoute(ctx) : notAllowed();
  if (method === "GET") return getRoute(ctx, id);
  if (method === "PATCH") return updateRoute(ctx, id);
  if (method === "DELETE") return deleteRoute(ctx, id);
  return notAllowed();
}

const notAllowed = () => Promise.reject(new HttpError(405, "Method not allowed"));

/** ?today=, else the server's day. */
function todayOf({ url, now }: Ctx): string {
  const asked = url.searchParams.get("today");
  if (asked === null || asked === "") return now.toISOString().slice(0, 10);
  if (!isValidDate(asked)) throw new HttpError(400, "today must be YYYY-MM-DD");
  return asked;
}

/** A required date parameter. */
function dateParam({ url }: Ctx, name: string): string {
  const v = url.searchParams.get(name);
  if (!isValidDate(v)) throw new HttpError(400, `${name} must be YYYY-MM-DD`);
  return v;
}

const callerId = (ctx: Ctx) => ctx.principal?.id ?? null;

async function listRoute(ctx: Ctx): Promise<Response> {
  const today = todayOf(ctx);
  const { family, access } = await ctx.load("view");
  return json({
    chores: listChores(ctx.db, family.id, today, callerId(ctx)),
    people: chorePeople(ctx.db, family.id),
    canEdit: access === "edit",
  });
}

async function agendaRoute(ctx: Ctx): Promise<Response> {
  const today = todayOf(ctx);
  const from = dateParam(ctx, "from");
  const to = dateParam(ctx, "to");
  const { family } = await ctx.load("view");
  return json(choreAgenda(ctx.db, family.id, { from, to, today }, callerId(ctx)));
}

async function createRoute(ctx: Ctx): Promise<Response> {
  const today = todayOf(ctx);
  const { family } = await ctx.load("edit");
  const body = await readBody(ctx.req);
  const chore = createChore(ctx.db, family.id, body, { createdById: callerId(ctx) }, ctx.now, today);
  return json({ chore }, 201);
}

async function getRoute(ctx: Ctx, id: string): Promise<Response> {
  const today = todayOf(ctx);
  const { family } = await ctx.load("view");
  return json({ chore: getChore(ctx.db, family.id, id, today, callerId(ctx)) });
}

async function updateRoute(ctx: Ctx, id: string): Promise<Response> {
  const today = todayOf(ctx);
  const { family } = await ctx.load("edit");
  const body = await readBody(ctx.req);
  return json({ chore: updateChore(ctx.db, family.id, id, body, ctx.now, today, callerId(ctx)) });
}

async function deleteRoute(ctx: Ctx, id: string): Promise<Response> {
  const { family } = await ctx.load("edit");
  deleteChore(ctx.db, family.id, id);
  return json({ deleted: id });
}

/** Editors tick off any chore (a repeating one per occurrence), viewers only those assigned to
 *  them. */
async function doneRoute(ctx: Ctx, id: string): Promise<Response> {
  const today = todayOf(ctx);
  const { family, access } = await ctx.load("view");
  const body = await readBody(ctx.req);
  if (typeof body.done !== "boolean") throw new HttpError(400, "done must be true or false");
  const row = getChoreRow(ctx.db, family.id, id);
  if (!row) throw new HttpError(404, "Chore not found");
  const userId = ctx.requireUser().id;
  if (access !== "edit" && row.assigneeUserId !== userId) {
    throw new HttpError(403, "You can only mark your own chores done");
  }
  return json({ chore: setChoreDone(ctx.db, family.id, id, body.done, { day: body.day, userId }, ctx.now, today) });
}

/** Any member, for themselves. */
async function subscribeRoute(ctx: Ctx, id: string): Promise<Response> {
  const today = todayOf(ctx);
  const { family } = await ctx.load("view");
  const body = await readBody(ctx.req);
  if (typeof body.subscribed !== "boolean") throw new HttpError(400, "subscribed must be true or false");
  const userId = ctx.requireUser().id;
  return json({ chore: setChoreSubscribed(ctx.db, family.id, id, userId, body.subscribed, today) });
}
