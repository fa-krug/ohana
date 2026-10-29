// The REST API of a family: /api/v1/families/{familyId}/... (family-planner's handler.ts,
// family part). Every module plugs a route function into the dispatcher: it gets a `Ctx` (who
// asks, the family lookup with access checks, the store) and answers, or returns null for paths
// that aren't its own. Signed in by the session cookie or an API token (Authorization: Bearer);
// the calendar feed (GET .../{feedId}/calendar.ics) is public and looked up by its feed id only.

import { ZodError } from "zod";
import type { Db } from "@/lib/db";
import { SESSION_COOKIE, getAppUrl } from "@/lib/auth/config";
import { AuthError } from "@/lib/auth/errors";
import { assertSameOrigin } from "@/lib/auth/origin";
import { type User, findToken, touchToken } from "@/lib/auth/tokens";
import { getRole } from "@/lib/families/roles";
import { type CalendarStore, DrizzleCalendarStore, type FamilyRow } from "@/lib/calendar/store";
import { CORS, HttpError, json } from "./http";

/**
 * What a request may do, from most to least:
 * - `edit`: everything (an editor of the family)
 * - `view`: read everything (a viewer)
 * - `feed`: only the calendar feed (the feed id, or the legacy id, without signing in)
 */
export type Access = "edit" | "view" | "feed";

export const ACCESS_RANK: Record<Access, number> = { feed: 0, view: 1, edit: 2 };

export interface Loaded {
  family: FamilyRow;
  access: Access;
}

export interface Ctx {
  db: Db;
  store: CalendarStore;
  req: Request;
  url: URL;
  method: string;
  /** The id in the path: /families/{id}/... (the feed or legacy id for calendar.ics). */
  token: string;
  /** The path parts after the id. */
  rest: string[];
  /** Absolute API base for links, e.g. https://ohana.example/api/v1 */
  publicBase: string;
  /** Who is asking; null without signing in (only the calendar feed allows that). */
  principal: User | null;
  now: Date;
  /** The signed-in user; 401 without one. */
  requireUser(): User;
  /** Loads the family; 404 unless the user is a member, 403 unless the role gives `need`. */
  load(need: Access): Promise<Loaded>;
  /** Like load, and runs `query` for the family's id alongside the lookup. */
  loadWith<T>(need: Access, query: (familyId: string) => Promise<T>): Promise<[Loaded, T]>;
}

/** A module's routes: a response, or null when the path isn't one of its own. */
export type FamilyRoute = (ctx: Ctx) => Promise<Response> | null;

export interface FamilyApiOptions {
  db: Db;
  /** Public URL of the app (default: APP_URL), for absolute links. */
  appUrl?: string;
  now?: () => Date;
}

// Family ids are UUIDs (or family-planner's 20-character ids after the import); feed and legacy
// ids are alphanumeric. Anything else can't be one.
const FAMILY_ID_RE = /^[A-Za-z0-9-]{10,64}$/;
const FEED_ID_RE = /^[A-Za-z0-9]{10,64}$/;

const DENIED: Partial<Record<Access, string>> = { view: "You can only view this family" };

function cookieValue(req: Request, name: string): string | null {
  for (const part of (req.headers.get("cookie") ?? "").split(";")) {
    const i = part.indexOf("=");
    if (i > 0 && part.slice(0, i).trim() === name) return decodeURIComponent(part.slice(i + 1).trim());
  }
  return null;
}

/** The user of a request: an API token (Bearer) or, without one, the session cookie. */
function authenticate(db: Db, req: Request, now: Date): { user: User; via: "token" | "cookie" } | null {
  const header = req.headers.get("authorization");
  if (header) {
    const match = /^Bearer\s+(\S+)$/i.exec(header);
    const found = match ? findToken(db, match[1], "api", now) : null;
    if (!found) throw new HttpError(401, "Your session has ended, sign in again");
    touchToken(db, found.token, now);
    return { user: found.user, via: "token" };
  }
  const raw = cookieValue(req, SESSION_COOKIE);
  const found = raw ? findToken(db, raw, "session", now) : null;
  if (!found) return null;
  touchToken(db, found.token, now);
  return { user: found.user, via: "cookie" };
}

export function errorResponse(err: unknown): Response {
  if (err instanceof HttpError) return json({ error: err.message }, err.status, err.headers);
  if (err instanceof AuthError) return json({ error: err.message }, err.status);
  if (err instanceof ZodError) return json({ error: err.issues[0]?.message ?? "Invalid input." }, 400);
  console.error(err);
  return json({ error: "Internal error" }, 500);
}

/** The route handler for /api/v1/families/{id}/...: tries `routes` in order. */
export function createFamilyApi(routes: FamilyRoute[], options: FamilyApiOptions) {
  const { db } = options;

  async function route(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const now = options.now?.() ?? new Date();
    const store = new DrizzleCalendarStore(db, () => now);
    const path = url.pathname.replace(/^.*?\/api\/v1(?=\/)/, "").replace(/\/+$/, "");
    const parts = path.split("/").filter(Boolean).map(decodeURIComponent);
    if (parts[0] !== "families" || parts.length < 2) throw new HttpError(404, "Not found");
    const method = req.method;
    const token = parts[1];
    const rest = parts.slice(2);
    // The calendar feed is public and never sends a cookie or token: no account lookups for it.
    const isFeed = rest.length === 1 && rest[0] === "calendar.ics" && method === "GET";

    let principal: User | null = null;
    if (!isFeed) {
      const auth = authenticate(db, req, now);
      if (auth) {
        // A page of another site can't change anything with the visitor's cookie.
        if (auth.via === "cookie" && method !== "GET" && method !== "HEAD") assertSameOrigin(req);
        if (auth.user.onboardingStep === "SET_CREDENTIALS") {
          throw new HttpError(403, "Set your password first");
        }
        principal = auth.user;
      }
    }

    const requireUser = (): User => {
      if (!principal) throw new HttpError(401, "Sign in first");
      return principal;
    };

    async function load(need: Access): Promise<Loaded> {
      if (need === "feed") {
        if (!FEED_ID_RE.test(token)) throw new HttpError(404, "Family not found");
        const family = await store.findFeed(token);
        if (!family) throw new HttpError(404, "Family not found");
        return { family, access: "feed" };
      }
      if (!FAMILY_ID_RE.test(token)) throw new HttpError(404, "Family not found");
      const user = requireUser();
      // Not a member reads the same as no such family: ids don't reveal anything. Being an
      // administrator doesn't open families either.
      const role = getRole(db, token, user.id);
      const family = role ? await store.getFamily(token) : null;
      if (!role || !family) throw new HttpError(404, "Family not found");
      const access: Access = role === "editor" ? "edit" : "view";
      if (ACCESS_RANK[access] < ACCESS_RANK[need]) throw new HttpError(403, DENIED[access]!);
      return { family, access };
    }

    async function loadWith<T>(need: Access, query: (familyId: string) => Promise<T>): Promise<[Loaded, T]> {
      // The family is loaded first: queries run synchronously against SQLite anyway, and
      // nothing is read for someone who may not see it.
      const loaded = await load(need);
      return [loaded, await query(loaded.family.id)];
    }

    const ctx: Ctx = {
      db,
      store,
      req,
      url,
      method,
      token,
      rest,
      publicBase: `${(options.appUrl ?? getAppUrl()).replace(/\/+$/, "")}/api/v1`,
      principal,
      now,
      requireUser,
      load,
      loadWith,
    };
    for (const r of routes) {
      const res = r(ctx);
      if (res) return await res;
    }
    throw new HttpError(404, "Not found");
  }

  return async function handler(req: Request): Promise<Response> {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    try {
      return await route(req);
    } catch (err) {
      return errorResponse(err);
    }
  };
}
