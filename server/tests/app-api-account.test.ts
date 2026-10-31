// The native app's account routes (lib/auth/app-routes.ts, /api/v1/me/...), signed in with
// the device's API token: profile, email, password, passkeys, API tokens, browser sessions.

import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { authTokens, passkeyCredentials, users } from "@/lib/db/schema";
import { handleAccountApp } from "@/lib/auth/app-routes";
import { hashPassword, verifyPassword } from "@/lib/auth/password";
import { MAX_FAILURES } from "@/lib/auth/rate-limit";
import { homeFor } from "@/lib/auth/redirect";
import { createToken, listTokens } from "@/lib/auth/tokens";
import type { Db } from "@/lib/db";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeUser } from "@/lib/test/factories";

type Res = { status: number; data: any };

const PASSWORD = "correct horse battery";

function addPasskey(db: Db, userId: string, deviceName = "iPhone") {
  return db
    .insert(passkeyCredentials)
    .values({
      id: randomUUID(),
      userId,
      credentialId: Buffer.from(randomUUID()),
      publicKey: Buffer.from("key"),
      deviceName,
      createdAt: NOW,
    })
    .returning()
    .get();
}

async function setup(opts: { password?: boolean; passkey?: boolean } = {}) {
  const db = createTestDb();
  const user = makeUser(db, {
    email: "anna@test",
    name: "Anna",
    password: opts.password === false ? "" : await hashPassword(PASSWORD),
  });
  if (opts.passkey) addPasskey(db, user.id);
  const device = createToken(db, { userId: user.id, kind: "api", name: "iPhone (app)" }, NOW);
  const call = async (method: string, path: string, body?: unknown, token = device.token): Promise<Res> => {
    const res = await handleAccountApp(
      db,
      new Request(`http://ohana.test/api/v1/me/${path}`, {
        method,
        headers: { authorization: `Bearer ${token}`, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
        body: body !== undefined ? JSON.stringify(body) : undefined,
      }),
      path.split("/").filter(Boolean),
      NOW,
    );
    const text = await res.text();
    return { status: res.status, data: text ? JSON.parse(text) : null };
  };
  const session = () => createToken(db, { userId: user.id, kind: "session" }, NOW);
  return { db, user, device, call, session };
}

describe("authentication", () => {
  it("needs an API token, not a session or nothing", async () => {
    const s = await setup();
    expect((await s.call("GET", "account", undefined, "nope")).status).toBe(401);
    expect((await s.call("GET", "account", undefined, s.session().token)).status).toBe(401);
    expect((await s.call("GET", "nothing")).status).toBe(404);
    expect((await s.call("POST", "account")).status).toBe(405);
  });
});

describe("GET /me/account", () => {
  it("answers the user, passkeys, tokens with the device's own marked, and the browser sessions", async () => {
    const s = await setup({ passkey: true });
    createToken(s.db, { userId: s.user.id, kind: "api", name: "Home Assistant" }, NOW);
    s.session();
    const res = await s.call("GET", "account");
    expect(res.status).toBe(200);
    expect(res.data.user).toMatchObject({ email: "anna@test", name: "Anna", hasPassword: true, hasPasskey: true });
    expect(res.data.passkeys).toEqual([
      { id: expect.any(String), deviceName: "iPhone", createdAt: NOW.toISOString(), lastUsedAt: null },
    ]);
    expect(res.data.tokens.map((t: any) => [t.name, t.current])).toEqual([
      ["iPhone (app)", true],
      ["Home Assistant", false],
    ]);
    expect(res.data.tokens[0].lastUsedAt).toBe(NOW.toISOString()); // this request used it
    expect(res.data.sessions).toBe(1);
  });
});

describe("profile and email", () => {
  it("saves the name and language", async () => {
    const s = await setup();
    const res = await s.call("PATCH", "profile", { name: "  Anna K. ", preferredLanguage: "de" });
    expect(res.status).toBe(200);
    expect(res.data).toMatchObject({ name: "Anna K.", preferredLanguage: "de" });
    expect((await s.call("PATCH", "profile", { preferredLanguage: "fr" })).status).toBe(400);
    expect((await s.call("PATCH", "profile", { name: "x".repeat(101) })).status).toBe(400);
  });

  it("changes the email with the current password", async () => {
    const s = await setup();
    makeUser(s.db, { email: "ben@x.test" });
    expect((await s.call("PUT", "email", { newEmail: "anna@new.test", currentPassword: "wrong" })).data).toEqual({
      error: "Current password is incorrect.",
    });
    expect((await s.call("PUT", "email", { newEmail: "ben@x.test", currentPassword: PASSWORD })).status).toBe(409);
    expect((await s.call("PUT", "email", { newEmail: "not an email", currentPassword: PASSWORD })).status).toBe(400);
    const res = await s.call("PUT", "email", { newEmail: " Anna@New.test ", currentPassword: PASSWORD });
    expect(res.status).toBe(200);
    expect(res.data.email).toBe("anna@new.test");
  });

  it("refuses an email change without a password (that's confirmed with a passkey on the web)", async () => {
    const s = await setup({ password: false, passkey: true });
    const res = await s.call("PUT", "email", { newEmail: "anna@new.test", currentPassword: "" });
    expect(res).toEqual({ status: 400, data: { error: "Set a password or confirm with a passkey." } });
  });
});

describe("password", () => {
  it("changes it with the current one and signs out the browsers, not the device", async () => {
    const s = await setup();
    s.session();
    expect((await s.call("PUT", "password", { newPassword: "another fine password" })).status).toBe(400);
    expect((await s.call("PUT", "password", { currentPassword: PASSWORD, newPassword: "short" })).status).toBe(400);
    const res = await s.call("PUT", "password", { currentPassword: PASSWORD, newPassword: "another fine password" });
    expect(res.status).toBe(200);
    expect(res.data.hasPassword).toBe(true);
    const row = s.db.select().from(users).where(eq(users.id, s.user.id)).get()!;
    expect(await verifyPassword(row.password, "another fine password")).toBe(true);
    expect(listTokens(s.db, s.user.id, "session")).toHaveLength(0);
    expect(listTokens(s.db, s.user.id, "api")).toHaveLength(1);
  });

  it("sets a first one without a current one", async () => {
    const s = await setup({ password: false, passkey: true });
    const res = await s.call("PUT", "password", { newPassword: "another fine password" });
    expect(res.status).toBe(200);
    expect(res.data.hasPassword).toBe(true);
  });

  it("removes it only with a passkey left and the right password", async () => {
    const s = await setup();
    expect((await s.call("DELETE", "password", { currentPassword: PASSWORD })).data).toEqual({
      error: "Cannot remove your password without a passkey set.",
    });
    addPasskey(s.db, s.user.id);
    expect((await s.call("DELETE", "password", { currentPassword: "wrong" })).status).toBe(400);
    const res = await s.call("DELETE", "password", { currentPassword: PASSWORD });
    expect(res.status).toBe(200);
    expect(res.data.hasPassword).toBe(false);
    expect((await s.call("DELETE", "password", { currentPassword: PASSWORD })).data.error).toBe("No password is set.");
  });

  it("counts wrong passwords as failed sign-ins", async () => {
    const s = await setup();
    for (let i = 0; i < MAX_FAILURES; i++) {
      expect((await s.call("PUT", "email", { newEmail: "a@b.test", currentPassword: "wrong" })).status).toBe(400);
    }
    const res = await s.call("PUT", "password", { currentPassword: PASSWORD, newPassword: "another fine password" });
    expect(res.status).toBe(429);
  });
});

describe("passkeys", () => {
  it("renames and deletes, but not the last way to sign in", async () => {
    const s = await setup({ password: false });
    const a = addPasskey(s.db, s.user.id, "Mac");
    const b = addPasskey(s.db, s.user.id, "iPad");
    const renamed = await s.call("PATCH", `passkeys/${a.id}`, { deviceName: "  MacBook " });
    expect(renamed.status).toBe(200);
    expect(renamed.data.passkeys.find((p: any) => p.id === a.id).deviceName).toBe("MacBook");
    expect((await s.call("DELETE", `passkeys/${b.id}`)).data.passkeys).toHaveLength(1);
    expect((await s.call("DELETE", `passkeys/${a.id}`)).data).toEqual({
      error: "Cannot delete your only passkey without a password set.",
    });
    expect((await s.call("GET", "passkeys")).data.passkeys).toHaveLength(1);
  });

  it("doesn't touch someone else's", async () => {
    const s = await setup();
    const other = makeUser(s.db);
    const theirs = addPasskey(s.db, other.id);
    expect((await s.call("PATCH", `passkeys/${theirs.id}`, { deviceName: "x" })).status).toBe(404);
    expect((await s.call("DELETE", `passkeys/${theirs.id}`)).status).toBe(404);
  });
});

describe("API tokens", () => {
  it("creates one, shown once, and deletes it", async () => {
    const s = await setup();
    expect((await s.call("POST", "tokens", { name: " " })).status).toBe(400);
    const created = await s.call("POST", "tokens", { name: "Home Assistant" });
    expect(created.status).toBe(200);
    expect(created.data.token).toMatch(/^ohana_/);
    expect(created.data.item).toMatchObject({ name: "Home Assistant", current: false, lastUsedAt: null });
    expect((await s.call("GET", "tokens", undefined, created.data.token)).data.tokens.map((t: any) => t.current)).toEqual([
      false,
      true,
    ]);
    const deleted = await s.call("DELETE", `tokens/${created.data.item.id}`);
    expect(deleted.data).toEqual({ ok: true, signedOut: false });
    expect((await s.call("DELETE", `tokens/${created.data.item.id}`)).status).toBe(404);
  });

  it("deleting the device's own token signs it out", async () => {
    const s = await setup();
    expect((await s.call("DELETE", `tokens/${s.device.row.id}`)).data).toEqual({ ok: true, signedOut: true });
    expect((await s.call("GET", "account")).status).toBe(401);
  });

  it("doesn't delete someone else's", async () => {
    const s = await setup();
    const other = makeUser(s.db);
    const theirs = createToken(s.db, { userId: other.id, kind: "api", name: "x" }, NOW);
    expect((await s.call("DELETE", `tokens/${theirs.row.id}`)).status).toBe(404);
    expect(s.db.select().from(authTokens).where(eq(authTokens.id, theirs.row.id)).get()).toBeDefined();
  });
});

describe("sessions", () => {
  it("signs out every browser, keeping the API tokens", async () => {
    const s = await setup();
    s.session();
    s.session();
    expect((await s.call("GET", "sessions")).data).toEqual({ count: 2 });
    expect((await s.call("DELETE", "sessions")).data).toEqual({ ok: true, count: 2 });
    expect(listTokens(s.db, s.user.id, "session")).toHaveLength(0);
    expect((await s.call("GET", "sessions")).data).toEqual({ count: 0 });
  });
});

describe("homeFor (setup and onboarding follow `next`, e.g. the app's pairing)", () => {
  it("sends through the onboarding to next", () => {
    const next = "/device/pair?state=abcdefgh&deviceName=iPhone";
    expect(homeFor({ onboardingStep: "COMPLETED" })).toBe("/");
    expect(homeFor({ onboardingStep: "COMPLETED" }, next)).toBe(next);
    expect(homeFor({ onboardingStep: "ADD_PASSKEY" })).toBe("/onboarding");
    const onboarding = homeFor({ onboardingStep: "ADD_PASSKEY" }, next);
    expect(new URL(onboarding, "http://x").pathname).toBe("/onboarding");
    expect(new URL(onboarding, "http://x").searchParams.get("next")).toBe(next);
  });
});
