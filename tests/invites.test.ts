import { describe, expect, it } from "vitest";
import { registerWithPassword } from "@/lib/auth/register";
import { acceptInvite, createInvite, getInviteSummary, INVITE_TTL_MS, listInvites, revokeInvite } from "@/lib/families/invites";
import { getRole } from "@/lib/families/roles";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

describe("invites", () => {
  it("are made by editors and give their role once", () => {
    const db = createTestDb();
    const editor = makeUser(db);
    const joiner = makeUser(db);
    const f = makeFamily(db, editor.id);
    const { code } = createInvite(db, { id: editor.id }, f.id, "viewer", NOW);
    expect(getInviteSummary(db, code, NOW).familyName).toBe("Krug");
    expect(listInvites(db, { id: editor.id }, f.id, NOW)).toHaveLength(1);

    acceptInvite(db, joiner.id, code, NOW);
    expect(getRole(db, f.id, joiner.id)).toBe("viewer");
    expect(() => acceptInvite(db, makeUser(db).id, code, NOW)).toThrow(/already been used/);
    expect(listInvites(db, { id: editor.id }, f.id, NOW)).toHaveLength(0);
    expect(() => createInvite(db, { id: joiner.id }, f.id, "editor", NOW)).toThrow(expect.objectContaining({ status: 403 }));
  });

  it("expire, can be revoked, and don't add members twice", () => {
    const db = createTestDb();
    const editor = makeUser(db);
    const f = makeFamily(db, editor.id);
    const a = createInvite(db, { id: editor.id }, f.id, "editor", NOW);
    expect(() => acceptInvite(db, makeUser(db).id, a.code, new Date(NOW.getTime() + INVITE_TTL_MS))).toThrow(/expired/);
    expect(() => acceptInvite(db, editor.id, a.code, NOW)).toThrow(/already a member/);
    const [inv] = listInvites(db, { id: editor.id }, f.id, NOW);
    revokeInvite(db, { id: editor.id }, f.id, inv.id);
    expect(() => getInviteSummary(db, a.code, NOW)).toThrow(/Invalid/);
  });

  it("register new accounts with a password", async () => {
    const db = createTestDb();
    const editor = makeUser(db);
    const f = makeFamily(db, editor.id);
    const { code } = createInvite(db, { id: editor.id }, f.id, "editor", NOW);
    const user = await registerWithPassword(db, { email: "new@x.test", name: "Ana", password: "Tr0ub4dour&3", inviteCode: code }, NOW);
    expect(user).toMatchObject({ name: "Ana", isAdmin: false, onboardingStep: "ADD_PASSKEY", lastFamilyId: f.id });
    expect(getRole(db, f.id, user.id)).toBe("editor");
    // A failing registration leaves the invite unused.
    const second = createInvite(db, { id: editor.id }, f.id, "viewer", NOW);
    await expect(registerWithPassword(db, { email: "new@x.test", name: "", password: "Tr0ub4dour&3", inviteCode: second.code }, NOW)).rejects.toMatchObject({ status: 409 });
    expect(getInviteSummary(db, second.code, NOW).familyName).toBe("Krug");
  });
});
