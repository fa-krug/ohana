// Joining a family with an invite from the native app (lib/families/invite-routes.ts,
// /api/v1/invites/...): what the invite is, and accepting it with the API token's account.

import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { familyMembers, familyPeople, users } from "@/lib/db/schema";
import { handleInvitesApp } from "@/lib/families/invite-routes";
import { createInvite } from "@/lib/families/invites";
import { addPerson } from "@/lib/families/people";
import { createToken } from "@/lib/auth/tokens";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

type Res = { status: number; data: any };

function setup() {
  const db = createTestDb();
  const anna = makeUser(db, { email: "anna@test", name: "Anna" });
  const ben = makeUser(db, { email: "ben@test" });
  const family = makeFamily(db, anna.id);
  const as =
    (userId: string, now = NOW) =>
    async (method: string, path: string): Promise<Res> => {
      const token = createToken(db, { userId, kind: "api" }, NOW).token;
      const res = await handleInvitesApp(
        db,
        new Request(`http://ohana.test/api/v1/invites/${path}`, { method, headers: { authorization: `Bearer ${token}` } }),
        path.split("/").filter(Boolean),
        now,
      );
      const text = await res.text();
      return { status: res.status, data: text ? JSON.parse(text) : null };
    };
  return { db, anna, ben, family, asAnna: as(anna.id), asBen: as(ben.id), as };
}

describe("GET /invites/{code}", () => {
  it("says which family, role and whether one is in it already", async () => {
    const s = setup();
    const { code, expiresAt } = createInvite(s.db, { id: s.anna.id }, s.family.id, "editor", NOW);
    const res = await s.asBen("GET", code);
    expect(res).toEqual({
      status: 200,
      data: {
        familyId: s.family.id,
        familyName: "Krug",
        role: "editor",
        personName: null,
        expiresAt: expiresAt.toISOString(),
        alreadyMember: false,
      },
    });
    expect((await s.asAnna("GET", code)).data.alreadyMember).toBe(true);
  });

  it("names the person an invite is for", async () => {
    const s = setup();
    const { person } = addPerson(s.db, { id: s.anna.id }, s.family.id, { name: "Mia", birthday: "2018-11-15" }, NOW);
    const { code } = createInvite(s.db, { id: s.anna.id }, s.family.id, "viewer", NOW, person.id);
    expect((await s.asBen("GET", code)).data).toMatchObject({ personName: "Mia", role: "viewer" });
  });

  it("refuses unknown, expired and used invites, and calls without a token", async () => {
    const s = setup();
    expect((await s.asBen("GET", "nope")).data).toEqual({ error: "Invalid invite code." });
    const { code } = createInvite(s.db, { id: s.anna.id }, s.family.id, "viewer", NOW);
    const later = s.as(s.ben.id, new Date(NOW.getTime() + 8 * 24 * 3600 * 1000));
    expect((await later("GET", code)).data).toEqual({ error: "This invite has expired." });
    await s.asBen("POST", `${code}/accept`);
    expect((await s.asBen("GET", code)).data).toEqual({ error: "This invite has already been used." });
    const res = await handleInvitesApp(s.db, new Request(`http://ohana.test/api/v1/invites/${code}`), [code], NOW);
    expect(res.status).toBe(401);
  });
});

describe("POST /invites/{code}/accept", () => {
  it("makes the account a member and answers the family as /me lists it", async () => {
    const s = setup();
    const { code } = createInvite(s.db, { id: s.anna.id }, s.family.id, "viewer", NOW);
    expect((await s.asBen("GET", `${code}/accept`)).status).toBe(405);
    const res = await s.asBen("POST", `${code}/accept`);
    expect(res).toEqual({ status: 200, data: { id: s.family.id, name: "Krug", role: "viewer", memberCount: 2 } });
    expect(s.db.select().from(users).where(eq(users.id, s.ben.id)).get()?.lastFamilyId).toBe(s.family.id);
  });

  it("replaces the person it is for, taking the name and birthday", async () => {
    const s = setup();
    const { person } = addPerson(s.db, { id: s.anna.id }, s.family.id, { name: "Mia", birthday: "2018-11-15" }, NOW);
    const { code } = createInvite(s.db, { id: s.anna.id }, s.family.id, "editor", NOW, person.id);
    expect((await s.asBen("POST", `${code}/accept`)).data.role).toBe("editor");
    expect(s.db.select().from(familyPeople).all()).toEqual([]);
    expect(s.db.select().from(users).where(eq(users.id, s.ben.id)).get()?.name).toBe("Mia");
    const member = s.db.select().from(familyMembers).where(eq(familyMembers.userId, s.ben.id)).get();
    expect(member).toMatchObject({ role: "editor", birthday: "2018-11-15" });
  });

  it("refuses members of the family", async () => {
    const s = setup();
    const { code } = createInvite(s.db, { id: s.anna.id }, s.family.id, "viewer", NOW);
    expect((await s.asAnna("POST", `${code}/accept`)).data).toEqual({ error: "You are already a member of this family." });
  });
});
