// Agent tokens (POST /families/{id}/agent/token): a one-hour API token scoped to one family and
// the prompt for an outside AI agent. The token reaches that family's API only, never the
// account, the administration, invites, other families, new families or images. Runs the whole
// HTTP app (http/app.ts) on the process-wide database, here an in-memory one.

import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

vi.hoisted(() => {
  process.env.DATABASE_FILE = ":memory:";
  delete process.env.APP_URL;
  delete process.env.DISABLED_MODULES;
});

import { migrate } from "drizzle-orm/better-sqlite3/migrator";
import { eq } from "drizzle-orm";
import { db } from "@/lib/db";
import { authTokens, families } from "@/lib/db/schema";
import { createApp } from "@/http/app";
import { createToken } from "@/lib/auth/tokens";
import { handleAccountApp } from "@/lib/auth/app-routes";
import { createFamilyApi } from "@/lib/api/family-api";
import { handleFamily } from "@/lib/calendar/family-routes";
import { makeFamily, makeUser } from "@/lib/test/factories";

const app = createApp({ db });
const BASE = "http://localhost:3000/api/v1";

beforeAll(() => {
  migrate(db, { migrationsFolder: "./drizzle" });
});

afterEach(() => {
  delete process.env.DISABLED_MODULES;
});

async function call(token: string, method: string, path: string, body?: unknown) {
  const res = await app.request(path, {
    method,
    headers: { authorization: `Bearer ${token}`, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data: any = text;
  try {
    data = JSON.parse(text);
  } catch {
    // not JSON
  }
  return { status: res.status, data, headers: res.headers };
}

function setup() {
  const anna = makeUser(db, { name: "Anna", isAdmin: true });
  const ben = makeUser(db, { name: "Ben" });
  const family = makeFamily(db, anna.id, [{ userId: ben.id, role: "viewer" }]);
  const other = makeFamily(db, anna.id);
  const annaApi = createToken(db, { userId: anna.id, kind: "api", name: "Laptop" }, new Date()).token;
  const benApi = createToken(db, { userId: ben.id, kind: "api", name: "Phone" }, new Date()).token;
  return { anna, ben, family, other, annaApi, benApi };
}

describe("agent tokens", () => {
  it("mints a one-hour token and a prompt for the family", async () => {
    const { family, annaApi } = setup();
    const before = Date.now();
    const res = await call(annaApi, "POST", `/api/v1/families/${family.id}/agent/token`);
    expect(res.status).toBe(201);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(Object.keys(res.data).sort()).toEqual(["expiresAt", "prompt", "token"]);
    const { token, expiresAt, prompt } = res.data;
    expect(token).toMatch(/^ohana_/);
    const ttl = new Date(expiresAt).getTime() - before;
    expect(ttl).toBeGreaterThan(59 * 60_000);
    expect(ttl).toBeLessThanOrEqual(60 * 60_000 + 5_000);
    expect(prompt).toContain(token);
    expect(prompt).toContain(`${BASE}/families/${family.id}`);
    expect(prompt).toContain(family.id);
    expect(prompt).toContain(family.name);
    expect(prompt).toContain("https://ohana.fa-krug.de/openapi.yaml");
    expect(prompt).toContain(`GET ${BASE}/families/${family.id}/agent`);
    expect(prompt).toContain("valid for 1 hour");
    expect(prompt).toContain("read and write");
    expect(prompt).toContain("/knowledge/documents");

    // Listed with the account's API tokens (revocable in the app).
    const list = await call(annaApi, "GET", "/api/v1/me/tokens");
    const item = list.data.tokens.find((t: any) => t.name === "AI agent");
    expect(item).toMatchObject({ familyId: family.id, current: false });
    expect(new Date(item.expiresAt).toISOString()).toBe(expiresAt);
    const laptop = list.data.tokens.find((t: any) => t.name === "Laptop");
    expect(laptop).toMatchObject({ familyId: null, expiresAt: null, current: true });
  });

  it("works for its family's API, as the user", async () => {
    const { family, annaApi } = setup();
    const { token } = (await call(annaApi, "POST", `/api/v1/families/${family.id}/agent/token`)).data;
    expect((await call(token, "GET", `/api/v1/families/${family.id}?year=2026`)).status).toBe(200);
    expect((await call(token, "GET", `/api/v1/families/${family.id}/overview`)).status).toBe(200);
    expect((await call(token, "GET", `/api/v1/families/${family.id}/agent`)).status).toBe(200);
    expect((await call(token, "GET", `/api/v1/families/${family.id}/recipes`)).status).toBe(200);
    const renamed = await call(token, "PATCH", `/api/v1/families/${family.id}`, { name: "Krug-Agent" });
    expect(renamed.status).toBe(200);
    expect(db.select().from(families).where(eq(families.id, family.id)).get()?.name).toBe("Krug-Agent");
    // The server's info and health are public anyway.
    expect((await call(token, "GET", "/api/v1/server")).status).toBe(200);
    expect((await call(token, "GET", "/api/health")).status).toBe(200);
  });

  it("leaves members, invites, channels, the assistant's settings and the family itself alone", async () => {
    const { anna, ben, family, annaApi } = setup();
    const { token } = (await call(annaApi, "POST", `/api/v1/families/${family.id}/agent/token`)).data;
    const f = `/api/v1/families/${family.id}`;
    const held: [string, string, unknown?][] = [
      ["DELETE", `${f}/household`],
      ["POST", `${f}/household/members`, { email: "eve@example.com", role: "editor" }],
      ["PATCH", `${f}/household/members/${ben.id}`, { role: "editor" }],
      ["DELETE", `${f}/household/members/${ben.id}`],
      ["DELETE", `${f}/household/members/${anna.id}/photo`],
      ["POST", `${f}/household/people`, { name: "Eve", invite: "editor" }],
      ["POST", `${f}/household/invites`, { role: "editor" }],
      ["DELETE", `${f}/household/invites/x`],
      ["POST", `${f}/household/notifications/channels`, { name: "x", provider: "ntfy", target: "https://ntfy.sh/x" }],
      ["PUT", `${f}/household/notifications/events/appointment_found`, { enabled: true, channelIds: null }],
      ["PUT", `${f}/ai/settings`, { baseUrl: "https://evil.example/v1" }],
      ["POST", `${f}/ai/models`, { baseUrl: "https://evil.example/v1" }],
      ["POST", `${f}/ai/test`, { baseUrl: "https://evil.example/v1" }],
    ];
    for (const [method, path, body] of held) {
      const res = await call(token, method, path, body);
      expect([method, path, res.status]).toEqual([method, path, 403]);
      expect(res.data.error).toMatch(/AI agent/);
    }
    expect(db.select().from(families).where(eq(families.id, family.id)).get()).toBeTruthy();
    // Reading them is fine, and so is the rest of the household (the home address).
    expect((await call(token, "GET", `${f}/household`)).status).toBe(200);
    expect((await call(token, "GET", `${f}/ai/settings`)).status).toBe(200);
    expect((await call(token, "PUT", `${f}/household/home`, { address: "Hauptstr. 1, Berlin", lat: 52.52, lng: 13.4 })).status).toBe(200);
    // The app's own token still may.
    expect((await call(annaApi, "POST", `${f}/household/invites`, { role: "viewer" })).status).toBe(201);
  });

  it("is refused everywhere outside its family", async () => {
    const { family, other, annaApi } = setup();
    const { token } = (await call(annaApi, "POST", `/api/v1/families/${family.id}/agent/token`)).data;
    const refused: [string, string, unknown?][] = [
      ["GET", `/api/v1/families/${other.id}`],
      ["GET", `/api/v1/families/${other.id}/overview`],
      ["GET", `/api/v1/families/${other.id}/recipes`],
      ["GET", `/api/v1/families/${other.id}/geocode?q=Berlin`],
      ["PATCH", `/api/v1/families/${other.id}`, { name: "x" }],
      ["GET", "/api/v1/me"],
      ["DELETE", "/api/v1/me"],
      ["GET", "/api/v1/me/tokens"],
      ["POST", "/api/v1/me/tokens", { name: "forever" }],
      ["GET", "/api/v1/me/account"],
      ["PUT", "/api/v1/me/password", { newPassword: "a-long-new-password-1" }],
      ["PUT", "/api/v1/me/push", {}],
      ["GET", "/api/v1/admin/users"],
      ["GET", "/api/v1/admin/families"],
      ["POST", "/api/v1/families", { name: "Mine now" }],
      ["GET", "/api/v1/invites/ABCDEFGHJK"],
      ["POST", "/api/v1/invites/ABCDEFGHJK/accept", {}],
      ["GET", `/api/images/members/${family.id}/x.webp`],
      ["GET", "/api/v1/nothing"],
      // Encoded or dotted paths don't get it out of its family.
      ["GET", `/api/v1/families/${family.id}/../../me/tokens`],
      ["GET", `/api/v1/families/${family.id}/%2e%2e/%2e%2e/me/tokens`],
    ];
    for (const [method, path, body] of refused) {
      const res = await call(token, method, path, body);
      expect([path, res.status]).toEqual([path, 403]);
      expect(res.data).toEqual({ error: "This token only works for the family's API." });
    }
    // Nothing happened: no new token, still its one family.
    const names = (await call(annaApi, "GET", "/api/v1/me/tokens")).data.tokens.map((t: any) => t.name);
    expect(names).toEqual(["Laptop", "AI agent"]);
  });

  it("can't mint another token", async () => {
    const { family, annaApi } = setup();
    const { token } = (await call(annaApi, "POST", `/api/v1/families/${family.id}/agent/token`)).data;
    const res = await call(token, "POST", `/api/v1/families/${family.id}/agent/token`);
    expect(res.status).toBe(403);
    expect(res.data.error).toBeTruthy();
  });

  it("stops working when it expires", async () => {
    const { family, annaApi } = setup();
    const { token } = (await call(annaApi, "POST", `/api/v1/families/${family.id}/agent/token`)).data;
    db.update(authTokens).set({ expiresAt: new Date(Date.now() - 1000) }).where(eq(authTokens.familyId, family.id)).run();
    expect((await call(token, "GET", `/api/v1/families/${family.id}`)).status).toBe(401);
  });

  it("gives a viewer a read-only prompt and token", async () => {
    const { family, benApi } = setup();
    const res = await call(benApi, "POST", `/api/v1/families/${family.id}/agent/token`);
    expect(res.status).toBe(201);
    expect(res.data.prompt).toContain("**read-only**");
    expect(res.data.prompt).not.toContain("/knowledge/documents");
    const { token } = res.data;
    expect((await call(token, "GET", `/api/v1/families/${family.id}`)).status).toBe(200);
    expect((await call(token, "PATCH", `/api/v1/families/${family.id}`, { name: "Ben's" })).status).toBe(403);
  });

  it("is off with the assistant", async () => {
    const { family, annaApi } = setup();
    process.env.DISABLED_MODULES = "assistant";
    expect((await call(annaApi, "POST", `/api/v1/families/${family.id}/agent/token`)).status).toBe(404);
  });

  it("goes with its family", async () => {
    const { annaApi, anna } = setup();
    const doomed = makeFamily(db, anna.id);
    await call(annaApi, "POST", `/api/v1/families/${doomed.id}/agent/token`);
    expect(db.select().from(authTokens).where(eq(authTokens.familyId, doomed.id)).all()).toHaveLength(1);
    expect((await call(annaApi, "DELETE", `/api/v1/families/${doomed.id}/household`)).status).toBeLessThan(300);
    expect(db.select().from(authTokens).where(eq(authTokens.familyId, doomed.id)).all()).toHaveLength(0);
  });

  it("leaves unscoped API tokens working everywhere", async () => {
    const { family, other, annaApi } = setup();
    expect((await call(annaApi, "GET", "/api/v1/me")).status).toBe(200);
    expect((await call(annaApi, "GET", "/api/v1/me/tokens")).status).toBe(200);
    expect((await call(annaApi, "GET", "/api/v1/admin/users")).status).toBe(200);
    expect((await call(annaApi, "GET", `/api/v1/families/${family.id}`)).status).toBe(200);
    expect((await call(annaApi, "GET", `/api/v1/families/${other.id}`)).status).toBe(200);
    expect((await call(annaApi, "GET", `/api/v1/families/${other.id}/recipes`)).status).toBe(200);
  });

  it("is refused by the routes themselves too, not only at the /api door", async () => {
    const { anna, family, other } = setup();
    const { token } = createToken(db, { userId: anna.id, kind: "api", familyId: family.id, ttlMs: 3_600_000 }, new Date());
    const req = (path: string) => new Request(`http://localhost:3000${path}`, { headers: { authorization: `Bearer ${token}` } });
    const me = await handleAccountApp(db, req("/api/v1/me/tokens"), ["tokens"]);
    expect(me.status).toBe(403);
    const familyApi = createFamilyApi([handleFamily], { db });
    expect((await familyApi(req(`/api/v1/families/${other.id}`))).status).toBe(403);
    expect((await familyApi(req(`/api/v1/families/${family.id}`))).status).toBe(200);
  });
});
