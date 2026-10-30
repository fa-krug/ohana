import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { families, users } from "@/lib/db/schema";
import {
  createFamily,
  defaultFamilyId,
  deleteFamily,
  listFamiliesOf,
  renameFamily,
} from "@/lib/families/manage";
import { addMember, listMembers, removeMember, setRole } from "@/lib/families/members";
import { getRole, requireRole } from "@/lib/families/roles";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

describe("families", () => {
  it("makes the creator its editor and remembers it", () => {
    const db = createTestDb();
    const u = makeUser(db);
    const f = createFamily(db, { name: "  Krug  ", editorId: u.id }, NOW);
    expect(f.name).toBe("Krug");
    expect(getRole(db, f.id, u.id)).toBe("editor");
    expect(listFamiliesOf(db, u.id)).toEqual([{ id: f.id, name: "Krug", role: "editor", memberCount: 1 }]);
    expect(db.select().from(users).where(eq(users.id, u.id)).get()!.lastFamilyId).toBe(f.id);
    expect(() => createFamily(db, { name: " " }, NOW)).toThrow(/name/);
  });

  it("hides families from non-members and keeps viewers read-only", () => {
    const db = createTestDb();
    const editor = makeUser(db);
    const viewer = makeUser(db);
    const stranger = makeUser(db);
    const f = makeFamily(db, editor.id, [{ userId: viewer.id, role: "viewer" }]);
    expect(requireRole(db, { id: viewer.id }, f.id, "viewer")).toBe("viewer");
    expect(() => requireRole(db, { id: viewer.id }, f.id, "editor")).toThrow(expect.objectContaining({ status: 403 }));
    expect(() => requireRole(db, { id: stranger.id }, f.id, "viewer")).toThrow(expect.objectContaining({ status: 404 }));
    expect(() => renameFamily(db, { id: viewer.id }, f.id, "X", NOW)).toThrow(expect.objectContaining({ status: 403 }));
    renameFamily(db, { id: editor.id }, f.id, "Krugs", NOW);
    expect(listMembers(db, { id: viewer.id }, f.id).map((m) => m.role).sort()).toEqual(["editor", "viewer"]);
    // Admins acting as admins manage any family.
    renameFamily(db, { id: stranger.id, admin: true }, f.id, "Admin", NOW);
  });

  it("is deleted by its sole editor, or by an admin", () => {
    const db = createTestDb();
    const a = makeUser(db);
    const b = makeUser(db);
    const f = makeFamily(db, a.id, [{ userId: b.id, role: "viewer" }]);
    expect(() => deleteFamily(db, { id: a.id }, f.id)).toThrow(/other members/);
    removeMember(db, { id: a.id }, f.id, b.id);
    deleteFamily(db, { id: a.id }, f.id);
    expect(db.select().from(families).all()).toHaveLength(0);

    const g = makeFamily(db, a.id, [{ userId: b.id, role: "viewer" }]);
    deleteFamily(db, { id: b.id, admin: true }, g.id);
    expect(db.select().from(families).all()).toHaveLength(0);
  });

  it("opens the last family, else the first by name", () => {
    const db = createTestDb();
    const u = makeUser(db);
    const z = createFamily(db, { name: "Zeta", editorId: u.id }, NOW);
    const a = createFamily(db, { name: "Alpha", editorId: u.id }, NOW);
    expect(defaultFamilyId(db, { id: u.id, lastFamilyId: z.id })).toBe(z.id);
    expect(defaultFamilyId(db, { id: u.id, lastFamilyId: null })).toBe(a.id);
    expect(defaultFamilyId(db, { id: makeUser(db).id, lastFamilyId: null })).toBeNull();
  });
});

describe("members", () => {
  it("are added by the email of their account", () => {
    const db = createTestDb();
    const editor = makeUser(db);
    const other = makeUser(db, { email: "other@x.test" });
    const f = makeFamily(db, editor.id);
    const m = addMember(db, { id: editor.id }, f.id, { email: " OTHER@x.test ", role: "viewer" }, NOW);
    expect(m).toMatchObject({ userId: other.id, role: "viewer" });
    expect(() => addMember(db, { id: editor.id }, f.id, { email: "other@x.test", role: "viewer" }, NOW)).toThrow(expect.objectContaining({ status: 409 }));
    expect(() => addMember(db, { id: editor.id }, f.id, { email: "nobody@x.test", role: "viewer" }, NOW)).toThrow(expect.objectContaining({ status: 404 }));
    expect(() => addMember(db, { id: other.id }, f.id, { email: "x@x.test", role: "viewer" }, NOW)).toThrow(expect.objectContaining({ status: 403 }));
  });

  it("always leave the family an editor", () => {
    const db = createTestDb();
    const a = makeUser(db);
    const b = makeUser(db);
    const f = makeFamily(db, a.id, [{ userId: b.id, role: "viewer" }]);
    expect(() => setRole(db, { id: a.id }, f.id, a.id, "viewer")).toThrow(/at least one editor/);
    expect(() => removeMember(db, { id: a.id }, f.id, a.id)).toThrow(/at least one editor/);
    setRole(db, { id: a.id }, f.id, b.id, "editor");
    removeMember(db, { id: a.id }, f.id, a.id); // leaving is fine now
    expect(listMembers(db, { id: b.id }, f.id).map((m) => m.userId)).toEqual([b.id]);
    expect(() => removeMember(db, { id: b.id }, f.id, b.id)).toThrow(/only member/);
  });

  it("can leave as viewers without being editors", () => {
    const db = createTestDb();
    const a = makeUser(db);
    const b = makeUser(db);
    const f = makeFamily(db, a.id, [{ userId: b.id, role: "viewer" }]);
    db.update(users).set({ lastFamilyId: f.id }).where(eq(users.id, b.id)).run();
    removeMember(db, { id: b.id }, f.id, b.id);
    expect(getRole(db, f.id, b.id)).toBeNull();
    expect(db.select().from(users).where(eq(users.id, b.id)).get()!.lastFamilyId).toBeNull();
  });
});
