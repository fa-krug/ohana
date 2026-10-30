import { cache } from "react";
import { cookies, headers } from "next/headers";
import { notFound, redirect } from "next/navigation";
import { db } from "@/lib/db";
import { SESSION_COOKIE, SESSION_TTL_MS, getAllowedRpIds, resolveRpId } from "./config";
import { AuthError } from "./errors";
import { type AuthToken, type User, createToken, deleteToken, findToken, touchToken } from "./tokens";

export interface Auth {
  user: User;
  token: AuthToken;
}

// Memoized per request: the layout, page, and i18n each resolve the session
// independently, so without cache() the token lookup runs several times per navigation.
export const getAuth = cache(async (): Promise<Auth | null> => {
  const raw = (await cookies()).get(SESSION_COOKIE)?.value;
  if (!raw) return null;
  const now = new Date();
  const found = findToken(db, raw, "session", now);
  if (!found) return null;
  touchToken(db, found.token, now);
  return found;
});

export async function getSession(): Promise<User | null> {
  return (await getAuth())?.user ?? null;
}

export async function requireAuth(): Promise<Auth> {
  const auth = await getAuth();
  if (!auth) redirect("/login");
  return auth;
}

export async function requireUser(): Promise<User> {
  return (await requireAuth()).user;
}

/** For admin pages: a 404 for everyone else (pages check this themselves, since Next
 *  renders a layout and its page in parallel). */
export async function requireAdminPage(): Promise<User> {
  const user = await requireUser();
  if (!user.isAdmin) notFound();
  return user;
}

/** For route handlers: throws instead of redirecting. */
export async function requireSessionUser(): Promise<User> {
  const auth = await getAuth();
  if (!auth) throw new AuthError(401, "Not signed in.");
  return auth.user;
}

export async function setSessionCookie(userId: string, opts: { canReset?: boolean } = {}): Promise<void> {
  const { token } = createToken(db, { userId, kind: "session", canReset: opts.canReset }, new Date());
  (await cookies()).set(SESSION_COOKIE, token, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: Math.floor(SESSION_TTL_MS / 1000),
  });
}

export async function clearSessionCookie(): Promise<void> {
  const store = await cookies();
  const auth = await getAuth();
  if (auth) deleteToken(db, auth.token.id);
  store.delete(SESSION_COOKIE);
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
  const host = (await headers()).get("host") ?? "localhost";
  return resolveRpId(host, getAllowedRpIds());
}
