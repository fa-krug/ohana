import { pbkdf2Sync, randomBytes } from "node:crypto";
import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { users } from "@/lib/db/schema";
import { loginWithPassword } from "@/lib/auth/login";
import { isLegacyHash, verifyPassword } from "@/lib/auth/password";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeUser } from "@/lib/test/factories";

/** A hash the way family-planner made them (fewer iterations, to keep the test fast). */
function legacyHash(password: string, iterations = 1000): string {
  const salt = randomBytes(16);
  const hash = pbkdf2Sync(password, salt, iterations, 32, "sha256");
  return `pbkdf2-sha256$${iterations}$${salt.toString("base64")}$${hash.toString("base64")}`;
}

describe("family-planner password hashes", () => {
  it("are verified", async () => {
    const hash = legacyHash("Tr0ub4dour&3");
    expect(isLegacyHash(hash)).toBe(true);
    expect(await verifyPassword(hash, "Tr0ub4dour&3")).toBe(true);
    expect(await verifyPassword(hash, "wrong")).toBe(false);
  });

  it("reject malformed hashes", async () => {
    expect(await verifyPassword("pbkdf2-sha256$x$$", "a")).toBe(false);
    expect(await verifyPassword("pbkdf2-sha256$1000$c2FsdA==", "a")).toBe(false);
  });

  it("are replaced by argon2id at the next sign-in", async () => {
    const db = createTestDb();
    const user = makeUser(db, { email: "a@x.test", password: legacyHash("Tr0ub4dour&3") });
    await loginWithPassword(db, { email: "a@x.test", password: "Tr0ub4dour&3" }, NOW);
    const stored = db.select().from(users).where(eq(users.id, user.id)).get()!;
    expect(stored.password.startsWith("$argon2id$")).toBe(true);
    expect(await verifyPassword(stored.password, "Tr0ub4dour&3")).toBe(true);
  });
});
