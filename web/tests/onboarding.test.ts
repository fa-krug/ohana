import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { users } from "@/lib/db/schema";
import { createUser } from "@/lib/admin/users";
import { hashPassword, verifyPassword } from "@/lib/auth/password";
import { removePassword, setPassword, skipPasskey } from "@/lib/auth/password-management";
import { createToken, listTokens } from "@/lib/auth/tokens";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeUser } from "@/lib/test/factories";

const step = (db: ReturnType<typeof createTestDb>, id: string) =>
  db.select().from(users).where(eq(users.id, id)).get()!.onboardingStep;

describe("setting credentials", () => {
  it("lets a setup-link session set a password, then offers a passkey", async () => {
    const db = createTestDb();
    const { userId } = createUser(db, { email: "a@x.test", name: "", isAdmin: false }, NOW);
    const session = createToken(db, { userId, kind: "session", canReset: true }, NOW).row;
    await setPassword(db, userId, { newPassword: "Tr0ub4dour&3" }, session);
    expect(step(db, userId)).toBe("ADD_PASSKEY");
    skipPasskey(db, userId);
    expect(step(db, userId)).toBe("COMPLETED");
  });

  it("needs the current password, unless the session came from a setup link", async () => {
    const db = createTestDb();
    const user = makeUser(db, { email: "a@x.test", password: await hashPassword("Tr0ub4dour&3") });
    const normal = createToken(db, { userId: user.id, kind: "session" }, NOW).row;
    const other = createToken(db, { userId: user.id, kind: "session" }, NOW).row;
    await expect(setPassword(db, user.id, { newPassword: "N3w-passphrase!" }, normal)).rejects.toThrow(/Current password/);
    await setPassword(db, user.id, { currentPassword: "Tr0ub4dour&3", newPassword: "N3w-passphrase!" }, normal);
    // Other devices are signed out, this one stays.
    expect(listTokens(db, user.id, "session").map((t) => t.id)).toEqual([normal.id]);
    expect(other.id).not.toBe(normal.id);

    const reset = createToken(db, { userId: user.id, kind: "session", canReset: true }, NOW).row;
    await setPassword(db, user.id, { newPassword: "Th1rd-passphrase!" }, reset);
    const stored = db.select().from(users).where(eq(users.id, user.id)).get()!;
    expect(await verifyPassword(stored.password, "Th1rd-passphrase!")).toBe(true);
    expect(stored.onboardingStep).toBe("COMPLETED");
  });

  it("keeps a password when there is no passkey to sign in with", async () => {
    const db = createTestDb();
    const user = makeUser(db, { password: await hashPassword("Tr0ub4dour&3") });
    const s = createToken(db, { userId: user.id, kind: "session" }, NOW).row;
    await expect(removePassword(db, user.id, { currentPassword: "Tr0ub4dour&3" }, s)).rejects.toThrow(/without a passkey/);
  });
});
