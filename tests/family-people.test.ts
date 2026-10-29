import { describe, expect, it } from "vitest";
import { systemPrompt } from "@/lib/assistant/chat";
import type { FamilyRow } from "@/lib/calendar/store";
import { registerWithPassword } from "@/lib/auth/register";
import { acceptInvite, getInviteSummary, listInvites } from "@/lib/families/invites";
import { ageOn } from "@/lib/families/birthdays";
import { listMembers, setMemberBirthday } from "@/lib/families/members";
import { addPerson, familyNames, listPeople, removePerson, updatePerson } from "@/lib/families/people";
import { getRole } from "@/lib/families/roles";
import { deleteFamily } from "@/lib/families/manage";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

describe("members without an account", () => {
  it("are added, renamed and removed by editors, without an invite", () => {
    const db = createTestDb();
    const editor = makeUser(db, { name: "Sascha" });
    const viewer = makeUser(db, { email: "oma@x.test" });
    const f = makeFamily(db, editor.id, [{ userId: viewer.id, role: "viewer" }]);
    const { person, invite } = addPerson(db, { id: editor.id }, f.id, { name: " Mia " }, NOW);
    expect(person.name).toBe("Mia");
    expect(invite).toBeNull();
    expect(listInvites(db, { id: editor.id }, f.id, NOW)).toHaveLength(0);
    expect(listPeople(db, { id: viewer.id }, f.id).map((p) => p.name)).toEqual(["Mia"]);
    expect(() => addPerson(db, { id: editor.id }, f.id, { name: "mia" }, NOW)).toThrow(expect.objectContaining({ status: 409 }));
    expect(() => addPerson(db, { id: viewer.id }, f.id, { name: "Leo" }, NOW)).toThrow(expect.objectContaining({ status: 403 }));
    expect(() => listPeople(db, { id: makeUser(db).id }, f.id)).toThrow(expect.objectContaining({ status: 404 }));

    updatePerson(db, { id: editor.id }, f.id, person.id, { name: "Mia Sophie", birthday: "2019-05-03" }, NOW);
    expect(familyNames(db, f.id).map(({ id: _, ...p }) => p)).toEqual([
      { name: "Mia Sophie", account: false, birthday: "2019-05-03" },
      { name: "oma", account: true, birthday: null },
      { name: "Sascha", account: true, birthday: null },
    ]);
    removePerson(db, { id: editor.id }, f.id, person.id);
    expect(listPeople(db, { id: editor.id }, f.id)).toEqual([]);

    // Other families' people are out of reach.
    const other = makeUser(db);
    const g = makeFamily(db, other.id);
    const leo = addPerson(db, { id: other.id }, g.id, { name: "Leo" }, NOW).person;
    expect(() => removePerson(db, { id: editor.id }, f.id, leo.id)).toThrow(expect.objectContaining({ status: 404 }));
    deleteFamily(db, { id: other.id }, g.id);
  });

  it("have birthdays, as do members with an account", () => {
    const db = createTestDb();
    const editor = makeUser(db);
    const viewer = makeUser(db);
    const f = makeFamily(db, editor.id, [{ userId: viewer.id, role: "viewer" }]);
    const { person } = addPerson(db, { id: editor.id }, f.id, { name: "Leo", birthday: "2021-11-02" }, NOW);
    expect(person.birthday).toBe("2021-11-02");
    for (const bad of ["2021-02-30", "2026-11-03", "02.11.2021"]) {
      expect(() => updatePerson(db, { id: editor.id }, f.id, person.id, { name: "Leo", birthday: bad }, NOW)).toThrow(/Invalid birthday/);
    }
    updatePerson(db, { id: editor.id }, f.id, person.id, { name: "Leo", birthday: null }, NOW);
    expect(listPeople(db, { id: editor.id }, f.id)[0].birthday).toBeNull();

    // Members set their own; only editors set others'.
    setMemberBirthday(db, { id: viewer.id }, f.id, viewer.id, "1950-01-31", NOW);
    expect(() => setMemberBirthday(db, { id: viewer.id }, f.id, editor.id, "1980-01-01", NOW)).toThrow(expect.objectContaining({ status: 403 }));
    setMemberBirthday(db, { id: editor.id }, f.id, editor.id, "1980-06-15", NOW);
    expect(listMembers(db, { id: editor.id }, f.id).map((m) => m.birthday).sort()).toEqual(["1950-01-31", "1980-06-15"]);

    expect(ageOn("2019-05-03", "2026-05-02")).toBe(6);
    expect(ageOn("2019-05-03", "2026-05-03")).toBe(7);
    expect(ageOn("2020-02-29", "2027-02-28")).toBe(6);
  });

  it("can get an invite that replaces them with the account that accepts it", async () => {
    const db = createTestDb();
    const editor = makeUser(db);
    const f = makeFamily(db, editor.id);
    const { person, invite } = addPerson(db, { id: editor.id }, f.id, { name: "Leo", birthday: "2010-04-01", invite: "viewer" }, NOW);
    expect(invite).not.toBeNull();
    expect(getInviteSummary(db, invite!.code, NOW)).toMatchObject({ familyName: "Krug", personName: "Leo" });
    expect(listInvites(db, { id: editor.id }, f.id, NOW)[0].personId).toBe(person.id);

    const user = await registerWithPassword(db, { email: "leo@x.test", name: "", password: "Tr0ub4dour&3", inviteCode: invite!.code }, NOW);
    expect(getRole(db, f.id, user.id)).toBe("viewer");
    expect(listPeople(db, { id: editor.id }, f.id)).toEqual([]);
    expect(familyNames(db, f.id).find((n) => n.name === "Leo")).toEqual({ id: user.id, name: "Leo", account: true, birthday: "2010-04-01" });
  });

  it("lose their open invite when removed, and keep a named account's name", () => {
    const db = createTestDb();
    const editor = makeUser(db);
    const f = makeFamily(db, editor.id);
    const a = addPerson(db, { id: editor.id }, f.id, { name: "Ben", invite: "editor" }, NOW);
    removePerson(db, { id: editor.id }, f.id, a.person.id);
    expect(() => getInviteSummary(db, a.invite!.code, NOW)).toThrow(/Invalid/);

    const b = addPerson(db, { id: editor.id }, f.id, { name: "Ben", invite: "editor" }, NOW);
    const joiner = makeUser(db, { name: "Benjamin" });
    acceptInvite(db, joiner.id, b.invite!.code, NOW);
    expect(familyNames(db, f.id).map((n) => n.name)).toContain("Benjamin");
    expect(listPeople(db, { id: editor.id }, f.id)).toEqual([]);
  });
});

describe("the assistant", () => {
  it("knows the family's members by name", () => {
    const db = createTestDb();
    const editor = makeUser(db, { name: "Sascha" });
    const f = makeFamily(db, editor.id);
    addPerson(db, { id: editor.id }, f.id, { name: "Mia", birthday: "2019-05-03" }, NOW);
    const prompt = systemPrompt({
      family: { name: "Krug" } as FamilyRow,
      types: [], categories: [], accounts: [], currency: "EUR",
      today: "2026-11-01", year: 2026, page: "calendar", lang: "en", writes: true, search: false,
      people: familyNames(db, f.id),
    });
    expect(prompt).toContain("The family's members: Mia (no account, e.g. a child; born 2019-05-03, 7 years old), Sascha.");
  });
});
