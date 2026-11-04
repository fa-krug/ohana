// /families/{id}/finance/accounts/{accountId}/bank[/sync[/tan]] (handleFinance passes them on):
// linking an account to its bank and the syncs the worker runs (runner.ts). Members read,
// editors change and sync.

import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, readBody } from "@/lib/api/http";
import { listAccounts } from "@/lib/finance/finance";
import type { AccountRow } from "@/lib/finance/store";
import { deleteLink, saveLink } from "./links";
import { cancelActive, cancelSync, latestSync, startSync, submitTan, syncDto } from "./queue";

async function accountOf(ctx: Ctx, familyId: string, ref: string): Promise<AccountRow> {
  const accounts = await ctx.finance.listAccounts(familyId);
  const a = accounts.find((a) => a.id === ref) ??
    accounts.find((a) => a.name.toLowerCase() === ref.trim().toLowerCase());
  if (!a) throw new HttpError(404, `Unknown account "${ref}"`);
  return a;
}

/** The account's DTO, with its balance and bank. */
async function accountDto(ctx: Ctx, familyId: string, id: string) {
  const a = (await listAccounts(ctx.finance, familyId)).find((a) => a.id === id);
  if (!a) throw new HttpError(404, `Unknown account "${id}"`);
  return a;
}

export async function bankRoute(ctx: Ctx, ref: string): Promise<Response> {
  const tail = ctx.rest.slice(4).join("/");
  const { method } = ctx;

  if (tail === "") {
    // PUT: link (or change the link); DELETE: unlink (the transactions stay).
    if (method !== "PUT" && method !== "DELETE") throw new HttpError(405, "Method not allowed");
    const { family } = await ctx.load("edit");
    const account = await accountOf(ctx, family.id, ref);
    if (method === "PUT") {
      saveLink(ctx.db, family.id, account.id, await readBody(ctx.req), ctx.now);
    } else {
      cancelActive(ctx.db, family.id, account.id, ctx.now);
      deleteLink(ctx.db, family.id, account.id);
    }
    return json(await accountDto(ctx, family.id, account.id));
  }

  if (tail === "sync") {
    if (method === "GET") {
      const { family } = await ctx.load("view");
      const account = await accountOf(ctx, family.id, ref);
      const sync = latestSync(ctx.db, family.id, account.id);
      if (!sync) throw new HttpError(404, "This account hasn't synced yet");
      return json(syncDto(sync));
    }
    if (method === "POST") {
      const user = ctx.requireUser();
      const { family } = await ctx.load("edit");
      const account = await accountOf(ctx, family.id, ref);
      // {full: true}: the bank's whole history (an empty body: a normal sync).
      const raw = (await readBody(ctx.req)).full;
      if (raw !== undefined && raw !== null && typeof raw !== "boolean") throw new HttpError(400, "full must be true or false");
      const full = raw === true;
      const { sync, created } = startSync(ctx.db, family.id, account.id, user.id, ctx.now, full);
      return json(syncDto(sync), created ? 202 : 200);
    }
    if (method === "DELETE") {
      const { family } = await ctx.load("edit");
      const account = await accountOf(ctx, family.id, ref);
      const sync = cancelSync(ctx.db, family.id, account.id, ctx.now);
      if (!sync) throw new HttpError(404, "This account hasn't synced yet");
      return json(syncDto(sync));
    }
    throw new HttpError(405, "Method not allowed");
  }

  if (tail === "sync/tan") {
    if (method !== "POST") throw new HttpError(405, "Method not allowed");
    const { family } = await ctx.load("edit");
    const account = await accountOf(ctx, family.id, ref);
    const body = await readBody(ctx.req);
    return json(syncDto(submitTan(ctx.db, family.id, account.id, body.tan, ctx.now)));
  }

  throw new HttpError(404, "Not found");
}
