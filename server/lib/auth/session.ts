import { db } from "@/lib/db";
import { cookies, headers, perRequest } from "@/lib/http/request-context";
import { SESSION_COOKIE, cookieSecure, SESSION_TTL_MS, getAllowedRpIds, resolveRpId } from "./config";
import { AuthError } from "./errors";
import { type AuthToken, type User, createToken, deleteToken, findToken, touchToken } from "./tokens";

export interface Auth {
  user: User;
  token: AuthToken;
}

// The session of the current request (http/app.ts runs each request in a context), memoized
// per request and cookie value: a page and the locale both look it up, and signing in or out
// changes the cookie, so the next lookup sees the new one.
const sessionLookups = perRequest(() => new Map<string, Auth | null>());

function lookupSession(raw: string): Auth | null {
  const now = new Date();
  const found = findToken(db, raw, "session", now);
  if (!found) return null;
  touchToken(db, found.token, now);
  return found;
}

export async function getAuth(): Promise<Auth | null> {
  const raw = cookies().get(SESSION_COOKIE)?.value;
  if (!raw) return null;
  const seen = sessionLookups();
  if (!seen.has(raw)) seen.set(raw, lookupSession(raw));
  return seen.get(raw) ?? null;
}

export async function getSession(): Promise<User | null> {
  return (await getAuth())?.user ?? null;
}

/** For route handlers: throws instead of redirecting. */
export async function requireSessionUser(): Promise<User> {
  const auth = await getAuth();
  if (!auth) throw new AuthError(401, "Not signed in.");
  return auth.user;
}

export async function setSessionCookie(userId: string, opts: { canReset?: boolean } = {}): Promise<void> {
  const { token } = createToken(db, { userId, kind: "session", canReset: opts.canReset }, new Date());
  cookies().set(SESSION_COOKIE, token, {
    httpOnly: true,
    sameSite: "lax",
    secure: cookieSecure(),
    path: "/",
    maxAge: Math.floor(SESSION_TTL_MS / 1000),
  });
}

export async function clearSessionCookie(): Promise<void> {
  const auth = await getAuth();
  if (auth) deleteToken(db, auth.token.id);
  cookies().delete(SESSION_COOKIE);
}

/** The user of an API request: a personal API token as `Authorization: Bearer …`. */
export function getApiUser(req: Request): User | null {
  const header = req.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(\S+)$/i.exec(header);
  if (!match) return null;
  const now = new Date();
  const found = findToken(db, match[1], "api", now);
  if (!found) return null;
  touchToken(db, found.token, now);
  return found.user;
}

/** RP id derived from the current request Host header (port-stripped, validated). */
export async function currentRpId(): Promise<string> {
  const host = headers().get("host") ?? "localhost";
  return resolveRpId(host, getAllowedRpIds());
}
