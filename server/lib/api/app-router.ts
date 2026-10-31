// A small router for the native app's (apple/) account-level routes outside a family:
// /api/v1/me/..., /api/v1/admin/..., /api/v1/invites/.... Signed in only by an API token
// (Authorization: Bearer …, what the app pairs for); errors answer `{ "error": … }` like the
// family API. The route files under app/api/v1 pass the global db; tests pass their own.

import type { Db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { type AuthToken, type User, findToken, touchToken } from "@/lib/auth/tokens";
import { errorResponse } from "./family-api";
import { HttpError, json, readBody } from "./http";

export interface AppCtx {
  db: Db;
  req: Request;
  now: Date;
  user: User;
  /** The API token of this request (the device's token for the app). */
  token: AuthToken;
  /** The JSON body (an object; `{}` when empty). */
  body(): Promise<Record<string, unknown>>;
}

export type AppHandler = (ctx: AppCtx, args: string[]) => Promise<unknown> | unknown;
export type AppRoutes = [pattern: string[], methods: Record<string, AppHandler>][];

/** The user and token of a request's `Authorization: Bearer <api token>`; 401 otherwise. */
export function apiAuth(db: Db, req: Request, now: Date): { user: User; token: AuthToken } {
  const match = /^Bearer\s+(\S+)$/i.exec(req.headers.get("authorization") ?? "");
  const found = match ? findToken(db, match[1], "api", now) : null;
  if (!found) throw new AuthError(401, "A valid API token is required (Authorization: Bearer …).");
  touchToken(db, found.token, now);
  if (found.user.onboardingStep === "SET_CREDENTIALS") throw new HttpError(403, "Set your password first");
  return found;
}

/**
 * Answers a request whose path below the route's prefix is `path` (e.g. ["tokens", "<id>"]):
 * the first pattern of `routes` with the same length whose parts match ("*" matches any part,
 * passed on as `args`). `admin`: only administrators; everyone else gets 404, like the web's
 * admin pages.
 */
export async function runAppRoutes(
  routes: AppRoutes,
  db: Db,
  req: Request,
  path: string[],
  opts: { now?: Date; admin?: boolean } = {},
): Promise<Response> {
  try {
    const now = opts.now ?? new Date();
    const { user, token } = apiAuth(db, req, now);
    if (opts.admin && !user.isAdmin) throw new HttpError(404, "Not found");
    for (const [pattern, methods] of routes) {
      if (pattern.length !== path.length || !pattern.every((p, i) => p === "*" || p === path[i])) continue;
      const fn = methods[req.method];
      if (!fn) throw new HttpError(405, "Method not allowed");
      const args = path.filter((_, i) => pattern[i] === "*");
      let parsed: Record<string, unknown> | null = null;
      const ctx: AppCtx = {
        db,
        req,
        now,
        user,
        token,
        body: async () => (parsed ??= await readBody(req)),
      };
      const result = await fn(ctx, args);
      return json(result ?? { ok: true });
    }
    throw new HttpError(404, "Not found");
  } catch (e) {
    return errorResponse(e);
  }
}

/** The path parts of a catch-all route's params, decoded by Next already. */
export async function pathOf(params: Promise<{ path?: string[] }>): Promise<string[]> {
  return ((await params).path ?? []).filter(Boolean);
}
