// The members' colors (lib/families/colors.ts) and the entry types that take them: picking,
// shading, who a type belongs to through invites, removals, export / import, and the migration
// that brought them.

import Database from "better-sqlite3";
import { drizzle } from "drizzle-orm/better-sqlite3";
import { migrate } from "drizzle-orm/better-sqlite3/migrator";
import { eq } from "drizzle-orm";
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";
import * as schema from "@/lib/db/schema";
import { calEntries, calEntryTypes, familyMembers, familyPeople } from "@/lib/db/schema";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { handleFamily } from "@/lib/calendar/family-routes";
import { handleCalendar } from "@/lib/calendar/vacation";
import { handleFamilyApp } from "@/lib/families/app-routes";
import { calendarTools } from "@/lib/assistant/tools/calendar";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import {
  isMemberColor,
  MEMBER_COLORS,
  memberColorHex,
  NEUTRAL_COLOR,
  pickMemberColor,
  typeShade,
} from "@/lib/families/colors";
import { acceptInvite } from "@/lib/families/invites";
import { addPerson, removePerson } from "@/lib/families/people";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";
import type { ToolContext } from "@/lib/assistant/tools/common";

const BASE = "http://ohana.test/api/v1";
const blue = memberColorHex("blue");

function setup() {
  const db = createTestDb();
  const handler = createFamilyApi([handleFamilyApp, handleFamily, handleCalendar], { db, appUrl: "http://ohana.test", now: () => NOW });
  const as =
    (userId: string) =>
    async (method: string, path: string, body?: unknown): Promise<{ status: number; data: any }> => {
      const token = createToken(db, { userId, kind: "api" }, NOW).token;
      const res = await handler(
        new Request(BASE + path, {
          method,
          headers: { authorization: `Bearer ${token}`, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
          body: body !== undefined ? JSON.stringify(body) : undefined,
        }),
      );
      return { status: res.status, data: await res.json() };
    };
  const editor = makeUser(db, { email: "anna@test", name: "Anna" });
  const family = makeFamily(db, editor.id);
  return { db, family, editor, f: `/families/${family.id}`, call: as(editor.id), as };
}

describe("the palette", () => {
  it("knows its keys and hexes", () => {
    expect(MEMBER_COLORS.map((c) => c.key)).toEqual(["blue", "orange", "green", "red", "purple", "yellow", "teal", "pink", "indigo", "brown"]);
    expect(isMemberColor("teal")).toBe(true);
    expect(isMemberColor("#0090ff")).toBe(false);
    expect(memberColorHex("orange")).toBe("#f76b15");
    expect(memberColorHex("nope")).toBe(NEUTRAL_COLOR);
  });

  it("picks the first unused color, else the least used in palette order", () => {
    expect(pickMemberColor([])).toBe("blue");
    expect(pickMemberColor(["blue", "green"])).toBe("orange");
    const all = MEMBER_COLORS.map((c) => c.key);
    expect(pickMemberColor(all)).toBe("blue");
    expect(pickMemberColor([...all, "blue", "orange"])).toBe("green");
    expect(pickMemberColor([...all, ...all.filter((k) => k !== "pink")])).toBe("pink");
  });
});

describe("typeShade", () => {
  it("is the base at 0 and a distinct shade for each of the next ones", () => {
    expect(typeShade("#0090FF", 0)).toBe("#0090ff");
    for (const hex of [blue, memberColorHex("red"), NEUTRAL_COLOR]) {
      const shades = Array.from({ length: 16 }, (_, i) => typeShade(hex, i));
      expect(new Set(shades).size).toBe(16);
      for (const s of shades) expect(s).toMatch(/^#[0-9a-f]{6}$/);
    }
    expect(typeShade(blue, 1)).toBe("#4db1ff"); // lighter
    expect(typeShade(blue, 2)).toBe("#006bbd"); // darker
    // From 12 on the hue turns too: 12 is the base's lightness, another hue.
    expect(typeShade(blue, 12)).not.toBe(blue);
  });

  it("clamps the lightness", () => {
    const lightness = (hex: string) => {
      const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
      return (Math.max(r, g, b) + Math.min(r, g, b)) / 2;
    };
    // Teal is dark: -0.23 and -0.28 both end at the floor.
    expect(lightness(typeShade(memberColorHex("teal"), 4))).toBeCloseTo(0.15, 1);
    expect(typeShade(memberColorHex("teal"), 10)).toBe(typeShade(memberColorHex("teal"), 4));
    expect(lightness(typeShade("#e0e0e0", 9))).toBeLessThanOrEqual(0.885);
  });
});

describe("entry types and members", () => {
  it("are the creating editor's in a new family, in their color's shades by position", async () => {
    const s = setup();
    const types = (await s.call("GET", `${s.f}/types?year=2026`)).data;
    expect(types.map((t: any) => [t.id, t.memberId, t.color])).toEqual([
      ["holiday", s.editor.id, blue],
      ["vacation", s.editor.id, typeShade(blue, 1)],
      ["sick", s.editor.id, typeShade(blue, 2)],
    ]);
    // Moving a type to the front gives it the base color.
    await s.call("PATCH", `${s.f}/types/sick?year=2026`, { position: -1 });
    const after = (await s.call("GET", `${s.f}/types?year=2026`)).data;
    expect(after.map((t: any) => [t.id, t.color])).toEqual([
      ["sick", blue],
      ["holiday", typeShade(blue, 1)],
      ["vacation", typeShade(blue, 2)],
    ]);
    // Each member's types count on their own.
    const mia = addPerson(s.db, { id: s.editor.id }, s.family.id, { name: "Mia" }, NOW).person;
    expect(mia.color).toBe("orange");
    const res = await s.call("PATCH", `${s.f}/types/vacation?year=2026`, { memberId: mia.id });
    expect(res.data).toMatchObject({ memberId: mia.id, color: memberColorHex("orange") });
    expect((await s.call("GET", `${s.f}/types?year=2026`)).data.map((t: any) => t.color)).toEqual([
      blue,
      typeShade(blue, 1),
      memberColorHex("orange"),
    ]);
    // Copies into another year keep their members.
    const copied = (await s.call("POST", `${s.f}/types/copy`, { from: 2026, to: 2027 })).data;
    expect(copied.map((t: any) => t.memberId)).toEqual([s.editor.id, s.editor.id, mia.id]);
  });

  it("show up with their member in the overview's coming up", async () => {
    const s = setup();
    await s.call("POST", `${s.f}/entries`, { type: "vacation", from: "2026-11-05", to: "2026-11-06" });
    const upcoming = (await s.call("GET", `${s.f}/overview?today=2026-11-02`)).data.upcoming;
    expect(upcoming[0]).toEqual({
      kind: "entry",
      date: "2026-11-05",
      to: "2026-11-06",
      name: "Vacation",
      color: typeShade(blue, 1),
      icon: "beach.umbrella",
      member: { id: s.editor.id, name: "Anna", color: "blue", photo: null },
    });
  });

  it("move to the account that accepts a person's invite, with the person's color", async () => {
    const s = setup();
    const { person, invite } = addPerson(s.db, { id: s.editor.id }, s.family.id, { name: "Leo", color: "teal", invite: "viewer" }, NOW);
    await s.call("PATCH", `${s.f}/types/vacation?year=2026`, { memberId: person.id });
    const leo = makeUser(s.db, { name: "Leo" });
    acceptInvite(s.db, leo.id, invite!.code, NOW);
    expect(s.db.select().from(familyMembers).where(eq(familyMembers.userId, leo.id)).get()!.color).toBe("teal");
    const vacation = (await s.call("GET", `${s.f}/types?year=2026`)).data.find((t: any) => t.id === "vacation");
    expect(vacation).toMatchObject({ memberId: leo.id, color: memberColorHex("teal") });

    // Without a person, the account gets a color nobody has yet.
    const { invite: plain } = addPerson(s.db, { id: s.editor.id }, s.family.id, { name: "Tmp" }, NOW);
    expect(plain).toBeNull();
    const code = (await s.call("POST", `${s.f}/household/invites`, { role: "viewer" })).data.code;
    const ben = makeUser(s.db, { name: "Ben" });
    acceptInvite(s.db, ben.id, code, NOW);
    // blue (Anna), teal (Leo), orange (Tmp): Ben gets green.
    expect(s.db.select().from(familyMembers).where(eq(familyMembers.userId, ben.id)).get()!.color).toBe("green");
  });

  it("become nobody's when their person is removed", async () => {
    const s = setup();
    const mia = addPerson(s.db, { id: s.editor.id }, s.family.id, { name: "Mia" }, NOW).person;
    await s.call("PATCH", `${s.f}/types/sick?year=2026`, { memberId: mia.id });
    removePerson(s.db, { id: s.editor.id }, s.family.id, mia.id);
    expect(s.db.select().from(calEntryTypes).where(eq(calEntryTypes.id, "sick")).get()!.memberPersonId).toBeNull();
    const sick = (await s.call("GET", `${s.f}/types?year=2026`)).data.find((t: any) => t.id === "sick");
    expect(sick).toMatchObject({ memberId: null, color: NEUTRAL_COLOR });
  });

  it("of nobody may have their own color, which a member's color replaces", async () => {
    const s = setup();
    const green = memberColorHex("green");
    const holiday = await s.call("PATCH", `${s.f}/types/holiday?year=2026`, { memberId: null, colorKey: "green" });
    expect(holiday.data).toMatchObject({ memberId: null, colorKey: "green", color: green });
    // A second nobody's type of the same color gets a shade of it.
    const trip = await s.call("POST", `${s.f}/types?year=2026`, { name: "Trip", memberId: null, colorKey: "green" });
    expect(trip.data).toMatchObject({ colorKey: "green", color: typeShade(green, 1) });
    expect((await s.call("PATCH", `${s.f}/types/trip?year=2026`, { colorKey: "lime" })).status).toBe(400);

    // Given to a member, the type takes theirs and forgets its own.
    const anna = await s.call("PATCH", `${s.f}/types/trip?year=2026`, { memberId: s.editor.id, colorKey: "red" });
    expect(anna.data).toMatchObject({ memberId: s.editor.id, colorKey: null });
    await s.call("PATCH", `${s.f}/types/trip?year=2026`, { memberId: null });
    const back = (await s.call("GET", `${s.f}/types?year=2026`)).data.find((t: any) => t.id === "trip");
    expect(back).toMatchObject({ colorKey: null, color: NEUTRAL_COLOR });

    // null: gray again; the export keeps it, and so do copies into another year.
    await s.call("PATCH", `${s.f}/types/holiday?year=2026`, { colorKey: null });
    await s.call("PATCH", `${s.f}/types/trip?year=2026`, { colorKey: "pink" });
    const file = (await s.call("GET", `${s.f}/export`)).data;
    expect(file.types.find((t: any) => t.id === "trip").colorKey).toBe("pink");
    expect(file.types.find((t: any) => t.id === "holiday").colorKey).toBeNull();
    const copied = await s.call("POST", `${s.f}/types/copy`, { from: 2026, to: 2027 });
    expect(copied.data.find((t: any) => t.id === "trip")).toMatchObject({ colorKey: "pink", color: memberColorHex("pink") });
    const imported = await s.call("POST", `${s.f}/import?year=2026`, file);
    expect(imported.data.types.find((t: any) => t.id === "trip")).toMatchObject({ colorKey: "pink" });
  });

  it("are exported by name and found by name on import", async () => {
    const s = setup();
    const mia = addPerson(s.db, { id: s.editor.id }, s.family.id, { name: "Mia" }, NOW).person;
    await s.call("PATCH", `${s.f}/types/sick?year=2026`, { memberId: mia.id });
    await s.call("PATCH", `${s.f}/types/holiday?year=2026`, { memberId: null });
    const file = (await s.call("GET", `${s.f}/export`)).data;
    expect(file.types.map((t: any) => [t.id, t.member])).toEqual([
      ["holiday", null],
      ["vacation", "Anna"],
      ["sick", "Mia"],
    ]);
    expect(file.types[0]).not.toHaveProperty("color");
    expect(file.types[0]).not.toHaveProperty("memberId");

    // Another family: "mia " matches its Mia, "Anna" nobody there; a color is ignored.
    const other = makeUser(s.db, { name: "Otto" });
    const g = makeFamily(s.db, other.id);
    const theirMia = addPerson(s.db, { id: other.id }, g.id, { name: "MIA" }, NOW).person;
    file.types[2].member = " mia ";
    file.types[2].color = "#123456";
    const imported = await s.as(other.id)("POST", `/families/${g.id}/import?year=2026`, file);
    expect(imported.status).toBe(200);
    expect(imported.data.types.map((t: any) => [t.id, t.memberId])).toEqual([
      ["holiday", null],
      ["vacation", null],
      ["sick", theirMia.id],
    ]);
    expect(imported.data.members.map((m: any) => m.name)).toEqual(["MIA", "Otto"]);
  });
});

describe("the assistant's manage_entry_types", () => {
  function ctx(s: ReturnType<typeof setup>, userId: string): ToolContext {
    return {
      lang: "en",
      calendar: new DrizzleCalendarStore(s.db),
      finance: undefined as never,
      db: s.db,
      familyId: s.family.id,
      userId,
      net: {} as never,
      search: null,
    };
  }
  const run = (s: ReturnType<typeof setup>, args: Record<string, unknown>) =>
    calendarTools.manage_entry_types.run({ year: 2026, ...args }, ctx(s, s.editor.id));

  it("adds the user's types by default, takes a member by name and undoes back to them", async () => {
    const s = setup();
    const mia = addPerson(s.db, { id: s.editor.id }, s.family.id, { name: "Mia" }, NOW).person;
    const added = await run(s, { action: "add", name: "Kita" });
    expect(added.result).toMatchObject({ memberId: s.editor.id, member: "Anna", color: typeShade(blue, 3) });
    const forMia = await run(s, { action: "add", name: "Swimming", member: "mia" });
    expect(forMia.result).toMatchObject({ memberId: mia.id, member: "Mia", color: memberColorHex("orange") });
    await expect(run(s, { action: "add", name: "X", member: "Zoe" })).rejects.toThrow(/not a member/);

    const changed = await run(s, { action: "update", type: "kita", member: null });
    expect(changed.result).toMatchObject({ memberId: null, member: null, color: NEUTRAL_COLOR });
    expect(changed.change!.undo).toEqual([
      { method: "PATCH", path: "/types/kita?year=2026", body: { name: "Kita", memberId: s.editor.id, colorKey: null, role: "none", icon: null, appleSync: true } },
    ]);
    const teal = await run(s, { action: "update", type: "kita", color: "teal" });
    expect(teal.result).toMatchObject({ colorKey: "teal", color: memberColorHex("teal") });
    const listed = await calendarTools.get_calendar.run({ from: "2026-01-01", to: "2026-12-31" }, ctx(s, s.editor.id));
    expect((listed.result as any).types.find((t: any) => t.id === "swimming").member).toBe("Mia");

    // Icons: an own one is shown, and the undo of a change puts the stored one back.
    const trip = await run(s, { action: "add", name: "Trip", icon: "airplane" });
    expect(trip.result).toMatchObject({ icon: "airplane" });
    await expect(run(s, { action: "add", name: "Y", icon: "✈️" })).rejects.toThrow(/SF Symbol/);
    const reset = await run(s, { action: "update", type: "trip", icon: null, role: "covers" });
    expect(reset.result).toMatchObject({ icon: "checkmark.shield" });
    expect(reset.change!.undo[0].body).toEqual({ name: "Trip", memberId: s.editor.id, colorKey: null, role: "none", icon: "airplane", appleSync: true });
  });

  it("keeps a type out of Apple Calendar and reorders the year's types", async () => {
    const s = setup();
    const added = await run(s, { action: "add", name: "Private", appleSync: false });
    expect(added.result).toMatchObject({ appleSync: false });
    const on = await run(s, { action: "update", type: "private", appleSync: true });
    expect(on.result).toMatchObject({ appleSync: true });
    expect(on.change!.undo[0].body).toMatchObject({ appleSync: false });

    const before = (await new DrizzleCalendarStore(s.db).listTypes(s.family.id)).filter((t) => t.year === 2026).map((t) => t.id);
    const reversed = [...before].reverse();
    const ordered = await run(s, { action: "order", types: reversed });
    expect((ordered.result as any[]).map((t) => t.id)).toEqual(reversed);
    expect(ordered.change!.undo).toEqual([{ method: "POST", path: "/types/order?year=2026", body: { ids: before } }]);
    await expect(run(s, { action: "order", types: reversed.slice(1) })).rejects.toThrow(/each of 2026's types once/);
  });
});

describe("the migration", () => {
  it("keeps the entries, drops the types' colors, gives members distinct colors and notes SF Symbol icons", () => {
    const sql = readFileSync(resolve(__dirname, "../drizzle/0017_member_colors.sql"), "utf8");
    expect(sql).not.toMatch(/DROP TABLE\s+`?cal_entry_types/i);
    expect(sql).not.toMatch(/__new_cal_entry_types/);

    const dir = mkdtempSync(join(tmpdir(), "ohana-migrations-"));
    try {
      const src = resolve(__dirname, "../drizzle");
      cpSync(src, dir, { recursive: true });
      const journalPath = join(dir, "meta/_journal.json");
      const journal = JSON.parse(readFileSync(journalPath, "utf8")) as { entries: { tag: string }[] };
      const idx = journal.entries.findIndex((e) => e.tag === "0017_member_colors");
      expect(idx).toBeGreaterThan(0);
      writeFileSync(journalPath, JSON.stringify({ ...journal, entries: journal.entries.slice(0, idx) }));

      const sqlite = new Database(":memory:");
      sqlite.pragma("foreign_keys = ON");
      const db = drizzle(sqlite, { schema });
      migrate(db, { migrationsFolder: dir });
      const run = (q: string) => sqlite.prepare(q).run();
      for (const u of ["u1", "u2", "u3"]) run(`insert into users (id, email, name, created_at) values ('${u}', '${u}@x', '', 0)`);
      run("insert into families (id, name, created_at, updated_at) values ('f1', 'A', 0, 0), ('f2', 'B', 0, 0)");
      run("insert into family_members (family_id, user_id, role, joined_at) values ('f1', 'u2', 'editor', 2), ('f1', 'u1', 'editor', 1), ('f2', 'u3', 'editor', 5)");
      run("insert into family_people (id, family_id, name, created_at) values ('p1', 'f1', 'Mia', 9), ('p2', 'f2', 'Leo', 1)");
      run("insert into cal_entry_types (family_id, year, id, name, color, role, position) values ('f1', 2026, 'vacation', 'Vacation', '#22c55e', 'covers', 0)");
      run("insert into cal_entries (family_id, day, year, type_id) values ('f1', '2026-08-03', 2026, 'vacation'), ('f1', '2026-08-04', 2026, 'vacation')");
      const notes: [string, string, string][] = [
        ["2026-12-24", "🎄", "Christmas"],
        ["2026-12-25", "🎁", ""],
        ["2026-12-26", "gift", "Presents"],
        ["2026-12-27", "birthday.cake", ""],
        ["2026-12-28", "", "Just a comment"],
        ["2026-12-29", "Star", "Capital"],
        ["2026-12-30", "sun..max", ""],
        ["2026-12-31", "🎆", "x".repeat(500)],
      ];
      const note = sqlite.prepare("insert into cal_notes (family_id, day, icon, comment) values ('f1', ?, ?, ?)");
      for (const n of notes) note.run(...n);
      migrate(db, { migrationsFolder: src });

      expect(db.select().from(calEntries).all()).toHaveLength(2);
      expect(db.select().from(calEntryTypes).get()).toMatchObject({ id: "vacation", memberUserId: null, memberPersonId: null, icon: null });
      // Note icons that aren't SF Symbol names (emoji) moved to the front of the comment.
      const after = sqlite.prepare("select day, icon, comment from cal_notes order by day").all() as { day: string; icon: string; comment: string }[];
      expect(after.map((n) => [n.day, n.icon, n.comment])).toEqual([
        ["2026-12-24", "", "🎄 Christmas"],
        ["2026-12-25", "", "🎁"],
        ["2026-12-26", "gift", "Presents"],
        ["2026-12-27", "birthday.cake", ""],
        ["2026-12-28", "", "Just a comment"],
        ["2026-12-29", "", "Star Capital"],
        ["2026-12-30", "", "sun..max"],
        ["2026-12-31", "", `🎆 ${"x".repeat(498)}`],
      ]);
      expect(sqlite.prepare("select * from cal_entry_types").get()).not.toHaveProperty("color");
      const colors = Object.fromEntries([
        ...db.select().from(familyMembers).all().map((m) => [m.userId, m.color]),
        ...db.select().from(familyPeople).all().map((p) => [p.id, p.color]),
      ]);
      // f1: u1 (joined first), u2, then Mia; f2: u3, then Leo.
      expect(colors).toEqual({ u1: "blue", u2: "orange", p1: "green", u3: "blue", p2: "orange" });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
