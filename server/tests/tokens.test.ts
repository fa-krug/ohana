import { describe, expect, it } from "vitest";
import { authTokens } from "@/lib/db/schema";
import {
  createToken,
  deleteExpiredTokens,
  deleteUserTokens,
  findToken,
  hashToken,
  listTokens,
} from "@/lib/auth/tokens";
import { SESSION_TTL_MS } from "@/lib/auth/config";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeUser } from "@/lib/test/factories";

describe("auth tokens", () => {
  it("stores only the hash and finds the token by kind", () => {
    const db = createTestDb();
    const user = makeUser(db);
    const { token } = createToken(db, { userId: user.id, kind: "session" }, NOW);
    const rows = db.select().from(authTokens).all();
    expect(rows).toHaveLength(1);
    expect(rows[0].hash).toBe(hashToken(token));
    expect(JSON.stringify(rows)).not.toContain(token);
    expect(findToken(db, token, "session", NOW)?.user.id).toBe(user.id);
    expect(findToken(db, token, "api", NOW)).toBeNull();
    expect(findToken(db, "nope", "session", NOW)).toBeNull();
  });

  it("expires sessions; API tokens don't expire", () => {
    const db = createTestDb();
    const user = makeUser(db);
    const session = createToken(db, { userId: user.id, kind: "session" }, NOW);
    const api = createToken(db, { userId: user.id, kind: "api", name: "script" }, NOW);
    expect(api.token.startsWith("ohana_")).toBe(true);
    const later = new Date(NOW.getTime() + SESSION_TTL_MS + 1);
    expect(findToken(db, session.token, "session", later)).toBeNull();
    expect(findToken(db, api.token, "api", later)?.token.name).toBe("script");
    // The expired session was removed on lookup.
    expect(listTokens(db, user.id, "session")).toHaveLength(0);
  });

  it("deletes a user's tokens except the one kept, and expired ones", () => {
    const db = createTestDb();
    const user = makeUser(db);
    const a = createToken(db, { userId: user.id, kind: "session" }, NOW);
    createToken(db, { userId: user.id, kind: "session" }, NOW);
    createToken(db, { userId: user.id, kind: "api" }, NOW);
    deleteUserTokens(db, user.id, "session", a.row.id);
    expect(listTokens(db, user.id, "session").map((t) => t.id)).toEqual([a.row.id]);
    expect(listTokens(db, user.id, "api")).toHaveLength(1);
    expect(deleteExpiredTokens(db, new Date(NOW.getTime() + SESSION_TTL_MS + 60_000))).toBe(1);
  });
});
