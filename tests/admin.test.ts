import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { users } from "@/lib/db/schema";
import { listAllFamilies } from "@/lib/admin/families";
import { createUser, deleteUser, listUsers, resetUser, updateUser } from "@/lib/admin/users";
import { redeemSetupLink } from "@/lib/auth/setup-link";
import { createToken, listTokens } from "@/lib/auth/tokens";
import { getRole } from "@/lib/families/roles";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const tokenOf = (url: string) => url.split("/setup-link/")[1];

describe("admin: users", () => {
  it("creates accounts that start with a setup link", () => {
    const db = createTestDb();
    const { userId, setupUrl } = createUser(db, { email: " New@X.test ", name: "Ana", isAdmin: false }, NOW);
    expect(setupUrl).toMatch(/^http:\/\/localhost:3000\/setup-link\/.+/);
    const listed = listUsers(db).find((u) => u.id === userId)!;
    expect(listed).toMatchObject({ email: "new@x.test", hasPassword: false, passkeyCount: 0, familyCount: 0, onboardingStep: "SET_CREDENTIALS" });
    expect(redeemSetupLink(db, tokenOf(setupUrl), NOW).id).toBe(userId);
    // One-time.
    expect(() => redeemSetupLink(db, tokenOf(setupUrl), NOW)).toThrow(/invalid or has expired/);
    expect(() => createUser(db, { email: "new@x.test", name: "", isAdmin: false }, NOW)).toThrow(expect.objectContaining({ status: 409 }));
  });

  it("issues a new setup link that replaces the old one and signs the user out", () => {
    const db = createTestDb();
    const { userId, setupUrl } = createUser(db, { email: "a@x.test", name: "", isAdmin: false }, NOW);
    createToken(db, { userId, kind: "session" }, NOW);
    const second = resetUser(db, userId, NOW);
    expect(listTokens(db, userId, "session")).toHaveLength(0);
    expect(() => redeemSetupLink(db, tokenOf(setupUrl), NOW)).toThrow();
    expect(redeemSetupLink(db, tokenOf(second.setupUrl), NOW).id).toBe(userId);
  });

  it("doesn't let admins demote or delete themselves", () => {
    const db = createTestDb();
    const admin = makeUser(db, { isAdmin: true });
    const other = makeUser(db, { email: "o@x.test" });
    expect(() => updateUser(db, admin.id, admin.id, { isAdmin: false })).toThrow(/own administrator/);
    expect(() => deleteUser(db, admin.id, admin.id)).toThrow(/own account/);
    updateUser(db, admin.id, other.id, { isAdmin: true, name: " Ole ", email: "OLE@x.test" });
    expect(db.select().from(users).where(eq(users.id, other.id)).get()).toMatchObject({ isAdmin: true, name: "Ole", email: "ole@x.test" });
    expect(() => updateUser(db, admin.id, other.id, { email: admin.email })).toThrow(expect.objectContaining({ status: 409 }));
  });

  it("deletes accounts and gives orphaned families a new editor", () => {
    const db = createTestDb();
    const admin = makeUser(db, { isAdmin: true });
    const editor = makeUser(db);
    const viewer = makeUser(db);
    const f = makeFamily(db, editor.id, [{ userId: viewer.id, role: "viewer" }]);
    deleteUser(db, admin.id, editor.id);
    expect(getRole(db, f.id, viewer.id)).toBe("editor");
    expect(listAllFamilies(db)[0].members.map((m) => m.userId)).toEqual([viewer.id]);
  });
});
