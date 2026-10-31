// The request being answered, for code that reads cookies and headers without having the
// request passed in (the session, the WebAuthn ceremony cookie, the locale). The HTTP server
// (http/app.ts) runs every request inside `runWithRequest`; cookies set here are added to its
// response as Set-Cookie headers. Outside a request (tests, the worker) there is no context:
// reading finds nothing and setting throws.

import { AsyncLocalStorage } from "node:async_hooks";

export interface CookieOptions {
  httpOnly?: boolean;
  sameSite?: "lax" | "strict" | "none";
  secure?: boolean;
  path?: string;
  /** Seconds. */
  maxAge?: number;
}

interface RequestState {
  req: Request;
  /** Cookies of the request, updated by set / delete so later reads see them. */
  jar: Map<string, string>;
  /** Set-Cookie header values for the response. */
  setCookies: string[];
  /** Per-request memo (see `perRequest`). */
  memo: Map<unknown, unknown>;
}

const store = new AsyncLocalStorage<RequestState>();

export function parseCookies(header: string | null): Map<string, string> {
  const jar = new Map<string, string>();
  for (const part of (header ?? "").split(";")) {
    const i = part.indexOf("=");
    if (i < 0) continue;
    const name = part.slice(0, i).trim();
    if (!name || jar.has(name)) continue;
    const raw = part.slice(i + 1).trim();
    try {
      jar.set(name, decodeURIComponent(raw));
    } catch {
      jar.set(name, raw);
    }
  }
  return jar;
}

export function serializeCookie(name: string, value: string, opts: CookieOptions = {}): string {
  const parts = [`${name}=${encodeURIComponent(value)}`, `Path=${opts.path ?? "/"}`];
  if (opts.maxAge !== undefined) parts.push(`Max-Age=${Math.floor(opts.maxAge)}`);
  if (opts.httpOnly) parts.push("HttpOnly");
  if (opts.secure) parts.push("Secure");
  if (opts.sameSite) parts.push(`SameSite=${opts.sameSite[0].toUpperCase()}${opts.sameSite.slice(1)}`);
  return parts.join("; ");
}

/** Runs `fn` with `req` as the current request; returns its result and the cookies it set. */
export async function runWithRequest<T>(req: Request, fn: () => Promise<T>): Promise<{ result: T; setCookies: string[] }> {
  const state: RequestState = { req, jar: parseCookies(req.headers.get("cookie")), setCookies: [], memo: new Map() };
  const result = await store.run(state, fn);
  return { result, setCookies: state.setCookies };
}

function current(): RequestState | undefined {
  return store.getStore();
}

/** The current request; throws outside one. */
export function currentRequest(): Request {
  const state = current();
  if (!state) throw new Error("No request in this context");
  return state.req;
}

/** The current request's headers (empty outside a request). */
export function headers(): Headers {
  return current()?.req.headers ?? new Headers();
}

/** The current request's cookies; `set` / `delete` also go into the response. */
export function cookies() {
  return {
    get(name: string): { value: string } | undefined {
      const value = current()?.jar.get(name);
      return value === undefined ? undefined : { value };
    },
    set(name: string, value: string, opts: CookieOptions = {}): void {
      const state = current();
      if (!state) throw new Error("Cookies can only be set while answering a request");
      state.jar.set(name, value);
      state.setCookies.push(serializeCookie(name, value, opts));
    },
    delete(name: string): void {
      const state = current();
      if (!state) return;
      state.jar.delete(name);
      state.setCookies.push(serializeCookie(name, "", { maxAge: 0 }));
    },
  };
}

/** Memoizes `fn` for the duration of one request (outside a request it isn't memoized). */
export function perRequest<T>(fn: () => T): () => T {
  const key = {};
  return () => {
    const state = current();
    if (!state) return fn();
    if (!state.memo.has(key)) state.memo.set(key, fn());
    return state.memo.get(key) as T;
  };
}
