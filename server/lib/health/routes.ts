// Check-ups and vaccinations of the family API (/api/v1/families/{id}/health…). Editors see and
// record everyone's, a viewer only their own. `today` (YYYY-MM-DD, default: the server's day) is
// the day the windows are worked out for, `lang` (en | de, default: the family's) the language
// of the titles. Changes answer with the member's new state.
//
// GET    /health?today=&lang=                   {members, canEdit, scan, asOf}
// POST   /health/records?today=&lang=           {memberId, records: [{id?, code, day?, status?, note?}]}
//                                               → 201 {records, replaced, member}
// PATCH  /health/records/{id}?today=&lang=      {day?, status?, note?} → {record, member}
// DELETE /health/records/{id}?today=&lang=      {deleted: id, member}
// POST   /health/past?today=&lang=              {memberId} → {records, member} (every closed window
//                                               without a record: done, date unknown)
// POST   /health/scan?today=&lang=              {memberId, pages: [base64 JPEG / PNG]} → {ai, items}
//                                               (suggestions read from the booklet's pages; nothing saved)

import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, readBody, todayParam } from "@/lib/api/http";
import type { AiEnv } from "@/lib/assistant/routes";
import { familyModel } from "@/lib/assistant/routes";
import { isLocale } from "@/lib/i18n/config";
import { familyLocale } from "@/lib/notifications/locale";
import { moduleEnabled } from "@/lib/server-info";
import {
  addRecords,
  deleteRecord,
  listHealth,
  markPastDone,
  memberHealth,
  recordInput,
  recordOut,
  recordsOf,
  requireMember,
  updateRecord,
} from "./health";
import { readBooklet, scanPages } from "./scan";
import { type Lang, SCHEDULE_AS_OF } from "./schedule";

const NO_STORE = { "cache-control": "no-store" };

/** Routes /families/{id}/health[/records[/{id}] | /past | /scan]; null for anything else. */
export function handleHealth(env: AiEnv) {
  return (ctx: Ctx): Promise<Response> | null => {
    if (ctx.rest[0] !== "health") return null;
    const [, sub, id, ...more] = ctx.rest;
    if (more.length) return notFound();
    if (sub === undefined) return ctx.method === "GET" ? listRoute(ctx, env) : notAllowed();
    if (sub === "records") return recordsRoutes(ctx, id);
    if (id !== undefined) return notFound();
    if (sub === "past") return ctx.method === "POST" ? pastRoute(ctx) : notAllowed();
    if (sub === "scan") return ctx.method === "POST" ? scanRoute(ctx, env) : notAllowed();
    return notFound();
  };
}

/** /health/records (POST) and /health/records/{id} (PATCH, DELETE). */
function recordsRoutes(ctx: Ctx, id: string | undefined): Promise<Response> {
  if (id === undefined) return ctx.method === "POST" ? addRoute(ctx) : notAllowed();
  if (ctx.method === "PATCH") return updateRoute(ctx, id);
  if (ctx.method === "DELETE") return deleteRoute(ctx, id);
  return notAllowed();
}

const notFound = () => Promise.reject(new HttpError(404, "Not found"));
const notAllowed = () => Promise.reject(new HttpError(405, "Method not allowed"));

/** ?today=, else the server's day. */
const todayOf = ({ url, now }: Ctx): string => todayParam(url, now);

function langOf(ctx: Ctx, familyId: string): Lang {
  const asked = ctx.url.searchParams.get("lang");
  return isLocale(asked) ? asked : familyLocale(ctx.db, familyId);
}

/** The family, and whose items the caller sees: null (an editor: everyone) or their own id. */
async function loadHealth(ctx: Ctx) {
  const today = todayOf(ctx);
  const { family, access } = await ctx.load("view");
  const viewerId = access === "edit" ? null : ctx.requireUser().id;
  return { family, access, viewerId, today, lang: langOf(ctx, family.id) };
}

async function aiReady(env: AiEnv, familyId: string): Promise<boolean> {
  if (!moduleEnabled("assistant")) return false;
  const row = await env.store.getAiSettings(familyId);
  return !!(row?.base_url && row.model);
}

async function listRoute(ctx: Ctx, env: AiEnv): Promise<Response> {
  const { family, access, viewerId, today, lang } = await loadHealth(ctx);
  return json(
    {
      members: listHealth(ctx.db, family.id, viewerId, today, lang),
      canEdit: access === "edit",
      scan: await aiReady(env, family.id),
      asOf: SCHEDULE_AS_OF,
    },
    200,
    NO_STORE,
  );
}

async function addRoute(ctx: Ctx): Promise<Response> {
  const { family, viewerId, today, lang } = await loadHealth(ctx);
  const body = await readBody(ctx.req);
  const member = requireMember(ctx.db, family.id, body.memberId, viewerId);
  if (!Array.isArray(body.records) || body.records.length === 0) throw new HttpError(400, "records must be a list");
  if (body.records.length > 100) throw new HttpError(400, "At most 100 records at a time");
  const inputs = body.records.map((r) => recordInput(r, member, today));
  const { records, replaced } = addRecords(ctx.db, family.id, member, inputs, { createdById: ctx.requireUser().id, now: ctx.now });
  return json(
    {
      records: records.map(recordOut),
      replaced: replaced.map(recordOut),
      member: memberHealth(ctx.db, family.id, member, today, lang),
    },
    201,
  );
}

async function updateRoute(ctx: Ctx, id: string): Promise<Response> {
  const { family, viewerId, today, lang } = await loadHealth(ctx);
  const body = await readBody(ctx.req);
  const { record } = updateRecord(ctx.db, family.id, id, body, viewerId, today, ctx.now);
  const member = requireMember(ctx.db, family.id, record.memberUserId ?? record.memberPersonId, viewerId);
  return json({ record: recordOut(record), member: memberHealth(ctx.db, family.id, member, today, lang) });
}

async function deleteRoute(ctx: Ctx, id: string): Promise<Response> {
  const { family, viewerId, today, lang } = await loadHealth(ctx);
  const row = deleteRecord(ctx.db, family.id, id, viewerId);
  const member = requireMember(ctx.db, family.id, row.memberUserId ?? row.memberPersonId, viewerId);
  return json({ deleted: id, member: memberHealth(ctx.db, family.id, member, today, lang) });
}

async function pastRoute(ctx: Ctx): Promise<Response> {
  const { family, viewerId, today, lang } = await loadHealth(ctx);
  const body = await readBody(ctx.req);
  const member = requireMember(ctx.db, family.id, body.memberId, viewerId);
  const records = markPastDone(ctx.db, family.id, member, today, { createdById: ctx.requireUser().id, now: ctx.now });
  return json({ records: records.map(recordOut), member: memberHealth(ctx.db, family.id, member, today, lang) });
}

/** Suggestions read from the booklet's pages with the family's AI; `ai: false` without it. */
async function scanRoute(ctx: Ctx, env: AiEnv): Promise<Response> {
  const { family, viewerId, today, lang } = await loadHealth(ctx);
  const body = await readBody(ctx.req);
  const member = requireMember(ctx.db, family.id, body.memberId, viewerId);
  if (!member.birthday) throw new HttpError(409, "Add the birthday first");
  const pages = scanPages(body.pages);
  const model = moduleEnabled("assistant") ? await familyModel(env, family.id) : null;
  if (!model) return json({ ai: false, items: [] }, 200, NO_STORE);
  const items = await readBooklet(
    model.provider,
    {
      name: member.name,
      birthday: member.birthday,
      today,
      lang,
      pages,
      known: recordsOf(ctx.db, family.id, member.id).map((r) => ({ code: r.code, day: r.day })),
    },
    env.modelNet,
    ctx.req.signal,
  );
  return json({ ai: true, items }, 200, NO_STORE);
}
