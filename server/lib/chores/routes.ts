// Chores of the family API (/api/v1/families/{id}/chores…). Members read, editors change; a
// viewer may mark the chores assigned to them done. `today` (YYYY-MM-DD, default: the
// server's day) is the day `next` is worked out for.
//
// GET    /chores?today=                 {chores, people, canEdit}
// POST   /chores?today=                 ChoreInput (+ id: a chore put back) → 201 {chore}
// GET    /chores/{id}?today=            {chore}
// PATCH  /chores/{id}?today=            the fields to change → {chore}
// DELETE /chores/{id}                   {deleted: id}
// POST   /chores/{id}/done?today=       {done} → {chore} (400 for a repeating chore)

import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, readBody } from "@/lib/api/http";
import { isValidDate } from "@/lib/calendar/dates";
import { chorePeople, createChore, deleteChore, getChore, getChoreRow, listChores, setChoreDone, updateChore } from "./chores";

/** Routes /families/{id}/chores[/{choreId}[/done]]; null for anything else. */
export function handleChores(ctx: Ctx): Promise<Response> | null {
  if (ctx.rest[0] !== "chores") return null;
  const [, id, sub, ...more] = ctx.rest;
  const { method } = ctx;
  if (more.length || (sub !== undefined && sub !== "done")) return Promise.reject(new HttpError(404, "Not found"));
  if (sub === "done") return method === "POST" ? doneRoute(ctx, id) : notAllowed();
  if (id === undefined) {
    if (method === "GET") return listRoute(ctx);
    if (method === "POST") return createRoute(ctx);
    return notAllowed();
  }
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

async function listRoute(ctx: Ctx): Promise<Response> {
  const today = todayOf(ctx);
  const { family, access } = await ctx.load("view");
  return json({
    chores: listChores(ctx.db, family.id, today),
    people: chorePeople(ctx.db, family.id),
    canEdit: access === "edit",
  });
}

async function createRoute(ctx: Ctx): Promise<Response> {
  const today = todayOf(ctx);
  const { family } = await ctx.load("edit");
  const body = await readBody(ctx.req);
  const chore = createChore(ctx.db, family.id, body, { createdById: ctx.principal?.id }, ctx.now, today);
  return json({ chore }, 201);
}

async function getRoute(ctx: Ctx, id: string): Promise<Response> {
  const today = todayOf(ctx);
  const { family } = await ctx.load("view");
  return json({ chore: getChore(ctx.db, family.id, id, today) });
}

async function updateRoute(ctx: Ctx, id: string): Promise<Response> {
  const today = todayOf(ctx);
  const { family } = await ctx.load("edit");
  const body = await readBody(ctx.req);
  return json({ chore: updateChore(ctx.db, family.id, id, body, ctx.now, today) });
}

async function deleteRoute(ctx: Ctx, id: string): Promise<Response> {
  const { family } = await ctx.load("edit");
  deleteChore(ctx.db, family.id, id);
  return json({ deleted: id });
}

/** Editors mark any single chore done or open, viewers only those assigned to them. */
async function doneRoute(ctx: Ctx, id: string): Promise<Response> {
  const today = todayOf(ctx);
  const { family, access } = await ctx.load("view");
  const body = await readBody(ctx.req);
  if (typeof body.done !== "boolean") throw new HttpError(400, "done must be true or false");
  const row = getChoreRow(ctx.db, family.id, id);
  if (!row) throw new HttpError(404, "Chore not found");
  if (access !== "edit" && row.assigneeUserId !== ctx.requireUser().id) {
    throw new HttpError(403, "You can only mark your own chores done");
  }
  return json({ chore: setChoreDone(ctx.db, family.id, id, body.done, ctx.now, today) });
}
