// The HTTP server (http/app.ts) end to end: the pages, the sign-in JSON routes with their
// cookies, pairing the app, the account page, links into a family, the API's server info and
// turned-off modules. Runs on the process-wide database, here an in-memory one.

import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

vi.hoisted(() => {
  process.env.DATABASE_FILE = ":memory:";
  delete process.env.APP_URL;
  delete process.env.WEBAUTHN_ORIGIN;
  delete process.env.WEBAUTHN_RP_ID;
});

import { migrate } from "drizzle-orm/better-sqlite3/migrator";
import { eq } from "drizzle-orm";
import { db } from "@/lib/db";
import { users } from "@/lib/db/schema";
import { createApp } from "@/http/app";
import { makeFamily } from "@/lib/test/factories";

const ORIGIN = "http://localhost:3000";
const app = createApp({ db });

beforeAll(() => {
  migrate(db, { migrationsFolder: "./drizzle" });
});

afterAll(() => {
  delete process.env.DISABLED_MODULES;
});

/** A browser: keeps the cookies it is given, sends same-origin JSON posts. */
class Browser {
  cookies = new Map<string, string>();

  private remember(res: Response) {
    for (const line of res.headers.getSetCookie()) {
      const [pair, ...attrs] = line.split(";");
      const i = pair.indexOf("=");
      const name = pair.slice(0, i);
      const value = decodeURIComponent(pair.slice(i + 1));
      const expired = attrs.some((a) => a.trim().toLowerCase() === "max-age=0");
      if (expired || !value) this.cookies.delete(name);
      else this.cookies.set(name, value);
    }
  }

  private cookieHeader(): Record<string, string> {
    if (this.cookies.size === 0) return {};
    return { cookie: [...this.cookies].map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("; ") };
  }

  async get(path: string): Promise<Response> {
    const res = await app.request(path, { headers: this.cookieHeader() });
    this.remember(res);
    return res;
  }

  async post(path: string, body: unknown = {}, headers: Record<string, string> = { origin: ORIGIN }): Promise<{ status: number; data: any }> {
    const res = await app.request(path, {
      method: "POST",
      headers: { "content-type": "application/json", ...headers, ...this.cookieHeader() },
      body: JSON.stringify(body),
    });
    this.remember(res);
    const text = await res.text();
    return { status: res.status, data: text ? JSON.parse(text) : null };
  }
}

describe("the HTTP server", () => {
  const browser = new Browser();
  let token = "";

  it("answers the health check and the server info", async () => {
    expect(await (await app.request("/api/health")).json()).toEqual({ status: "ok" });
    const info = await (await app.request("/api/v1/server")).json();
    expect(info).toMatchObject({ name: "Ohana", apiVersion: 1, modules: ["calendar", "finance", "meals", "appointments", "chores", "assistant"] });
  });

  it("sends a fresh server to the first-run setup", async () => {
    const res = await browser.get("/");
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/setup");
    expect((await browser.get("/login?next=/device/pair")).headers.get("location")).toBe("/setup?next=%2Fdevice%2Fpair");
  });

  it("renders the setup page with a strict content security policy", async () => {
    const res = await browser.get("/setup");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    expect(res.headers.get("content-security-policy")).toContain("script-src 'self'");
    const html = await res.text();
    expect(html.startsWith("<!doctype html>")).toBe(true);
    expect(html).toContain('data-form="setup"');
    expect(html).toContain("/assets/auth.js");
  });

  it("refuses sign-in requests from other sites", async () => {
    const res = await browser.post("/api/auth/setup", { email: "anna@example.com", name: "Anna", password: "a long family password" }, { origin: "https://evil.example" });
    expect(res.status).toBe(403);
  });

  it("creates the first account and signs it in", async () => {
    const res = await browser.post("/api/auth/setup", { email: "anna@example.com", name: "Anna", password: "a long family password" });
    expect(res.status).toBe(200);
    expect(res.data).toMatchObject({ email: "anna@example.com", isAdmin: true });
    expect(browser.cookies.has("ohana_session")).toBe(true);
    // The setup page is gone once there is an account.
    expect((await browser.get("/setup")).headers.get("location")).toBe("/login");
  });

  it("finishes the onboarding, then shows the start page", async () => {
    const first = await browser.get("/");
    if (first.status === 302) {
      expect(first.headers.get("location")).toMatch(/^\/onboarding/);
      expect((await browser.get("/onboarding")).status).toBe(200);
      expect((await browser.post("/api/auth/skip-passkey")).status).toBe(200);
    }
    const home = await browser.get("/");
    expect(home.status).toBe(200);
    const html = await home.text();
    expect(html).toContain("Anna");
    expect(html).toContain('href="ohana://"');
    // Signed in, the login page goes on to `next`.
    expect((await browser.get("/login?next=/account")).headers.get("location")).toBe("/account");
  });

  it("pairs the app: an API token through ohana://auth-callback", async () => {
    const page = await browser.get("/device/pair?state=state-1234&deviceName=iPhone");
    expect(page.status).toBe(200);
    expect(await page.text()).toContain('data-form="pair"');
    const res = await browser.post("/api/auth/pair", { state: "state-1234", deviceName: "iPhone" });
    expect(res.status).toBe(200);
    const callback = new URL(res.data.callbackUrl);
    expect(callback.protocol).toBe("ohana:");
    expect(callback.searchParams.get("state")).toBe("state-1234");
    token = callback.searchParams.get("token")!;
    const me = await app.request("/api/v1/me", { headers: { authorization: `Bearer ${token}` } });
    expect(me.status).toBe(200);
    expect((await me.json()).user.email).toBe("anna@example.com");
  });

  it("shows the account page with the way back to the app", async () => {
    const res = await browser.get("/account?state=state-5678");
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("ohana://account-callback?state=state-5678");
    expect(html).toContain('data-form="add-passkey"');
    // An invalid state isn't echoed into the page.
    expect(await (await browser.get("/account?state=%3Cx%3E")).text()).not.toContain("account-callback");
  });

  it("changes the password with the current one and the email", async () => {
    expect((await browser.post("/api/auth/password", { currentPassword: "wrong", newPassword: "another long password" })).status).toBe(400);
    expect((await browser.post("/api/auth/password", { currentPassword: "a long family password", newPassword: "another long password" })).status).toBe(200);
    expect((await browser.post("/api/auth/email", { newEmail: "anna@family.example.com", currentPassword: "a long family password" })).status).toBe(400);
    const res = await browser.post("/api/auth/email", { newEmail: "anna@family.example.com", currentPassword: "another long password" });
    expect(res.status).toBe(200);
    expect(db.select().from(users).where(eq(users.email, "anna@family.example.com")).get()).toBeTruthy();
  });

  it("switches the pages' language for the account too", async () => {
    expect((await browser.post("/api/auth/language", { lang: "de" })).status).toBe(200);
    expect(await (await browser.get("/account")).text()).toContain("Dein Konto");
    expect((await browser.post("/api/auth/language", { lang: "xx" })).status).toBe(400);
    await browser.post("/api/auth/language", { lang: "en" });
  });

  it("opens links into a family in the app", async () => {
    const res = await browser.get("/f/fam-1/meals/shopping/list-1?x=1");
    expect(res.status).toBe(200);
    expect(await res.text()).toContain('href="ohana://f/fam-1/meals/shopping/list-1?x=1"');
  });

  it("serves the static files and the self-removing service worker", async () => {
    const css = await app.request("/assets/auth.css");
    expect(css.status).toBe(200);
    expect(await css.text()).toContain("--primary");
    expect(await (await app.request("/sw.js")).text()).toContain("unregister");
  });

  it("answers unknown API paths with JSON", async () => {
    const res = await app.request("/api/v1/nothing");
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "Not found" });
  });

  it("answers a turned-off module's routes with 404", async () => {
    const anna = db.select().from(users).where(eq(users.email, "anna@family.example.com")).get()!;
    const family = makeFamily(db, anna.id);
    const get = (path: string) => app.request(`/api/v1/families/${family.id}${path}`, { headers: { authorization: `Bearer ${token}` } });
    expect((await get("/finance")).status).toBe(200);
    expect((await get("/recipes")).status).toBe(200);
    process.env.DISABLED_MODULES = "finance,meals";
    expect((await get("/finance")).status).toBe(404);
    expect((await get("/recipes")).status).toBe(404);
    expect((await get("/meals/status")).status).toBe(404);
    expect((await (await app.request("/api/v1/server")).json()).modules).toEqual(["calendar", "appointments", "chores", "assistant"]);
    delete process.env.DISABLED_MODULES;
  });

  it("signs the browser out", async () => {
    expect((await browser.post("/api/auth/logout")).status).toBe(200);
    expect(browser.cookies.has("ohana_session")).toBe(false);
    expect((await browser.get("/")).headers.get("location")).toBe("/login");
    expect((await browser.get("/account")).headers.get("location")).toBe("/login?next=%2Faccount");
  });
});
