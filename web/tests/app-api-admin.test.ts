// The native app's administration routes (lib/admin/app-routes.ts, /api/v1/admin/...):
// users and families, for administrators only (404 for everyone else, like the pages).

import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { calEntryTypes, families, familyMembers, users } from "@/lib/db/schema";
import { handleAdminApp } from "@/lib/admin/app-routes";
import { createToken, listTokens } from "@/lib/auth/tokens";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

type Res = { status: number; data: any };

beforeEach(() => {
  process.env.APP_URL = "http://ohana.test";
});
afterEach(() => {
  delete process.env.APP_URL;
});

function setup() {
  const db = createTestDb();
  const admin = makeUser(db, { email: "admin@test", name: "Admin", isAdmin: true });
  const anna = makeUser(db, { email: "anna@test", name: "Anna" });
  const ben = makeUser(db, { email: "ben@test", name: "Ben" });
  const as =
    (userId: string) =>
    async (method: string, path: string, body?: unknown, headers: Record<string, string> = {}): Promise<Res> => {
      const token = createToken(db, { userId, kind: "api" }, NOW).token;
      const res = await handleAdminApp(
        db,
        new Request(`http://ohana.test/api/v1/admin/${path}`, {
          method,
          headers: {
            authorization: `Bearer ${token}`,
            ...headers,
            ...(body !== undefined ? { "content-type": "application/json" } : {}),
          },
          body: body !== undefined ? JSON.stringify(body) : undefined,
        }),
        path.split("/").filter(Boolean),
        NOW,
      );
      const text = await res.text();
      return { status: res.status, data: text ? JSON.parse(text) : null };
    };
  return { db, admin, anna, ben, asAdmin: as(admin.id), asAnna: as(anna.id) };
}

describe("access", () => {
  it("is for administrators only: 404 for others, 401 without a token", async () => {
    const s = setup();
    expect((await s.asAnna("GET", "users")).status).toBe(404);
    expect((await s.asAnna("POST", "families", { name: "X" })).status).toBe(404);
    const res = await handleAdminApp(s.db, new Request("http://ohana.test/api/v1/admin/users"), ["users"], NOW);
    expect(res.status).toBe(401);
  });
});

describe("users", () => {
  it("lists them with what the page shows", async () => {
    const s = setup();
    makeFamily(s.db, s.anna.id);
    const res = await s.asAdmin("GET", "users");
    expect(res.status).toBe(200);
    expect(res.data.users.map((u: any) => [u.email, u.isAdmin, u.familyCount])).toEqual([
      ["admin@test", true, 0],
      ["anna@test", false, 1],
      ["ben@test", false, 0],
    ]);
    expect(res.data.users[1]).toMatchObject({
      name: "Anna",
      hasPassword: false,
      passkeyCount: 0,
      onboardingStep: "COMPLETED",
      createdAt: NOW.toISOString(),
    });
  });

  it("creates one with a setup link", async () => {
    const s = setup();
    const res = await s.asAdmin("POST", "users", { email: " Mia@Test ", name: "Mia", isAdmin: false });
    expect(res.status).toBe(200);
    expect(res.data.setupUrl).toMatch(/^http:\/\/ohana\.test\/setup-link\/.+/);
    expect(res.data.expiresAt).toBe(new Date(NOW.getTime() + 7 * 24 * 3600 * 1000).toISOString());
    const row = s.db.select().from(users).where(eq(users.id, res.data.userId)).get()!;
    expect(row).toMatchObject({ email: "mia@test", name: "Mia", isAdmin: false, onboardingStep: "SET_CREDENTIALS" });
    expect((await s.asAdmin("POST", "users", { email: "anna@test" })).status).toBe(409);
  });

  it("edits name, email and the admin flag, but not one's own admin flag", async () => {
    const s = setup();
    expect((await s.asAdmin("PATCH", `users/${s.anna.id}`, { name: "Anna K.", email: "anna@k.test", isAdmin: true })).status).toBe(
      200,
    );
    expect(s.db.select().from(users).where(eq(users.id, s.anna.id)).get()).toMatchObject({
      name: "Anna K.",
      email: "anna@k.test",
      isAdmin: true,
    });
    expect((await s.asAdmin("PATCH", `users/${s.anna.id}`, { email: "ben@test" })).status).toBe(409);
    expect((await s.asAdmin("PATCH", `users/${s.admin.id}`, { isAdmin: false })).data).toEqual({
      error: "You can't remove your own administrator rights.",
    });
    expect((await s.asAdmin("PATCH", "users/nope", { name: "x" })).status).toBe(404);
  });

  it("makes a new setup link, signing them out", async () => {
    const s = setup();
    createToken(s.db, { userId: s.anna.id, kind: "session" }, NOW);
    const res = await s.asAdmin("POST", `users/${s.anna.id}/setup-link`);
    expect(res.status).toBe(200);
    expect(res.data.setupUrl).toMatch(/\/setup-link\//);
    expect(listTokens(s.db, s.anna.id, "session")).toHaveLength(0);
  });

  it("deletes others, not oneself; families get a new editor", async () => {
    const s = setup();
    const family = makeFamily(s.db, s.anna.id, [{ userId: s.ben.id, role: "viewer" }]);
    expect((await s.asAdmin("DELETE", `users/${s.admin.id}`)).status).toBe(400);
    expect((await s.asAdmin("DELETE", `users/${s.anna.id}`)).data).toEqual({ ok: true });
    expect(s.db.select().from(familyMembers).where(eq(familyMembers.familyId, family.id)).all()).toMatchObject([
      { userId: s.ben.id, role: "editor" },
    ]);
  });
});

describe("families", () => {
  it("lists every family with its members, also those the admin isn't in", async () => {
    const s = setup();
    makeFamily(s.db, s.anna.id, [{ userId: s.ben.id, role: "viewer" }]);
    const res = await s.asAdmin("GET", "families");
    expect(res.status).toBe(200);
    expect(res.data.families).toHaveLength(1);
    expect(res.data.families[0]).toMatchObject({ name: "Krug", createdAt: NOW.toISOString() });
    expect(res.data.families[0].members.map((m: any) => [m.email, m.role])).toEqual([
      ["anna@test", "editor"],
      ["ben@test", "viewer"],
    ]);
  });

  it("creates one without members, in the admin's language", async () => {
    const s = setup();
    s.db.update(users).set({ preferredLanguage: "de" }).where(eq(users.id, s.admin.id)).run();
    const res = await s.asAdmin("POST", "families", { name: " Müller " });
    expect(res.status).toBe(200);
    expect(s.db.select().from(families).where(eq(families.id, res.data.id)).get()?.name).toBe("Müller");
    expect(s.db.select().from(familyMembers).where(eq(familyMembers.familyId, res.data.id)).all()).toEqual([]);
    const types = s.db.select().from(calEntryTypes).where(eq(calEntryTypes.familyId, res.data.id)).all();
    expect(types.some((t) => /Urlaub/.test(t.name))).toBe(true);
    expect((await s.asAdmin("POST", "families", { name: " " })).status).toBe(400);
  });

  it("renames and deletes any family", async () => {
    const s = setup();
    const family = makeFamily(s.db, s.anna.id, [{ userId: s.ben.id, role: "viewer" }]);
    expect((await s.asAdmin("PATCH", `families/${family.id}`, { name: "Krug-Schmidt" })).status).toBe(200);
    expect(s.db.select().from(families).where(eq(families.id, family.id)).get()?.name).toBe("Krug-Schmidt");
    expect((await s.asAdmin("DELETE", `families/${family.id}`)).status).toBe(200);
    expect(s.db.select().from(families).where(eq(families.id, family.id)).get()).toBeUndefined();
    expect((await s.asAdmin("DELETE", `families/${family.id}`)).status).toBe(404);
  });

  it("adds members by email, sets roles and removes them; a family keeps an editor", async () => {
    const s = setup();
    const family = makeFamily(s.db, s.anna.id);
    const f = `families/${family.id}/members`;
    expect((await s.asAdmin("POST", f, { email: "nobody@test", role: "viewer" })).status).toBe(404);
    expect((await s.asAdmin("POST", f, { email: "BEN@test", role: "viewer" })).status).toBe(200);
    expect((await s.asAdmin("POST", f, { email: "ben@test", role: "viewer" })).status).toBe(409);
    expect((await s.asAdmin("PATCH", `${f}/${s.anna.id}`, { role: "viewer" })).status).toBe(400);
    expect((await s.asAdmin("PATCH", `${f}/${s.ben.id}`, { role: "boss" })).status).toBe(400);
    expect((await s.asAdmin("PATCH", `${f}/${s.ben.id}`, { role: "editor" })).status).toBe(200);
    expect((await s.asAdmin("PATCH", `${f}/${s.anna.id}`, { role: "viewer" })).status).toBe(200);
    expect((await s.asAdmin("DELETE", `${f}/${s.ben.id}`)).status).toBe(400); // the only editor
    expect((await s.asAdmin("DELETE", `${f}/${s.anna.id}`)).status).toBe(200);
    expect(s.db.select().from(familyMembers).where(eq(familyMembers.familyId, family.id)).all()).toMatchObject([
      { userId: s.ben.id, role: "editor" },
    ]);
  });
});
