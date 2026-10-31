// The HTTP server: the JSON API (/api, used by the native app), the sign-in pages and their
// static files. Every request runs in a request context (lib/http/request-context.ts), so the
// session and locale code can read cookies; cookies set there go into the response.

import { Hono } from "hono";
import { serveStatic } from "@hono/node-server/serve-static";
import type { Db } from "@/lib/db";
import { runWithRequest } from "@/lib/http/request-context";
import { apiRoutes } from "./api";
import { authRoutes } from "./auth-api";
import { pageRoutes } from "./pages/routes";

/** Content-Security-Policy of the pages: their own script and stylesheet only. */
const PAGE_CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self'",
  "img-src 'self' data:",
  "connect-src 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
  "base-uri 'none'",
  "object-src 'none'",
].join("; ");

export interface AppOptions {
  db: Db;
  /** Folder with the static files (default ./public). */
  publicDir?: string;
}

export function createApp({ db, publicDir = "./public" }: AppOptions): Hono {
  const app = new Hono();

  app.use("*", async (c, next) => {
    const { setCookies } = await runWithRequest(c.req.raw, async () => {
      await next();
    });
    const headers = c.res.headers;
    if (setCookies.length > 0 || (headers.get("content-type") ?? "").startsWith("text/html")) {
      // Responses of fetch / static files can have immutable headers: copy before changing.
      c.res = new Response(c.res.body, c.res);
      for (const cookie of setCookies) c.res.headers.append("Set-Cookie", cookie);
      if ((c.res.headers.get("content-type") ?? "").startsWith("text/html")) {
        c.res.headers.set("Content-Security-Policy", PAGE_CSP);
        c.res.headers.set("X-Frame-Options", "DENY");
        c.res.headers.set("Referrer-Policy", "same-origin");
        c.res.headers.set("Cache-Control", "no-store");
      }
    }
    c.res.headers.set("X-Content-Type-Options", "nosniff");
  });

  app.route("/api/auth", authRoutes(db));
  app.route("/api", apiRoutes(db));
  app.route("/", pageRoutes(db));
  app.use("/*", serveStatic({ root: publicDir }));

  app.notFound((c) => (c.req.path.startsWith("/api/") ? c.json({ error: "Not found" }, 404) : c.text("Not found", 404)));
  app.onError((err, c) => {
    console.error(`[http] ${c.req.method} ${c.req.path} failed:`, err);
    return c.req.path.startsWith("/api/") ? c.json({ error: "Internal error" }, 500) : c.text("Something went wrong.", 500);
  });
  return app;
}
