// The calendar part of family-planner's tests/api.test.ts, against Ohana's family API on the
// in-memory database (Drizzle store), signed in with API tokens or the session cookie.

import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { calEntries, calEntryTypes, calNotes, families, familyMembers } from "@/lib/db/schema";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { SESSION_COOKIE } from "@/lib/auth/config";
import { handleFamily } from "@/lib/calendar/family-routes";
import { handleCalendar } from "@/lib/calendar/vacation";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import { calendarSummary } from "@/lib/calendar/summary";
import { createFamily, deleteFamily } from "@/lib/families/manage";
import { memberColorHex, typeShade } from "@/lib/families/colors";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const BASE = "http://ohana.test/api/v1";

type Res = { status: number; data: any; headers: Headers };
type Call = (method: string, path: string, body?: unknown, headers?: Record<string, string>) => Promise<Res>;

function setup() {
  const db = createTestDb();
  const handler = createFamilyApi([handleFamily, handleCalendar], { db, appUrl: "http://ohana.test", now: () => NOW });
  const request =
    (auth: Record<string, string>): Call =>
    async (method, path, body, headers = {}) => {
      const res = await handler(
        new Request(BASE + path, {
          method,
          headers: { ...auth, ...(body !== undefined ? { "content-type": "application/json" } : {}), ...headers },
          body: body !== undefined ? JSON.stringify(body) : undefined,
        }),
      );
      const text = await res.text();
      let data: any = text;
      try {
        data = JSON.parse(text);
      } catch {
        /* ics */
      }
      return { status: res.status, data, headers: res.headers };
    };
  const as = (token: string | null) => request(token ? { authorization: `Bearer ${token}` } : {});
  const apiToken = (userId: string) => createToken(db, { userId, kind: "api" }, NOW).token;
  const owner = makeUser(db, { email: "owner@test", isAdmin: true });
  const call = as(apiToken(owner.id));
  let viewers = 0;
  const viewerOf = (familyId: string) => {
    const viewer = makeUser(db, { email: `viewer${++viewers}@test` });
    db.insert(familyMembers).values({ familyId, userId: viewer.id, role: "viewer", joinedAt: NOW }).run();
    return as(apiToken(viewer.id));
  };
  return { db, handler, call, as, request, apiToken, owner, viewerOf };
}

/** A new family of the owner (presets in 2026), and `view`: a call as a viewer of it. */
function newFamily(s: ReturnType<typeof setup>) {
  const family = makeFamily(s.db, s.owner.id);
  return { id: family.id, view: s.viewerOf(family.id) };
}

describe("new families", () => {
  it("get the preset types in the current year", () => {
    const db = createTestDb();
    const u = makeUser(db);
    const f = createFamily(db, { name: "Krug", editorId: u.id }, NOW);
    const types = db
      .select()
      .from(calEntryTypes)
      .where(eq(calEntryTypes.familyId, f.id))
      .orderBy(calEntryTypes.position)
      .all();
    expect(types.map((t) => [t.year, t.id, t.name, t.role, t.position, t.icon])).toEqual([
      [2026, "holiday", "Holiday", "day_off", 0, null],
      [2026, "vacation", "Vacation", "covers", 1, "beach.umbrella"],
      [2026, "sick", "Sick", "none", 2, "cross.case"],
    ]);
  });

  it("name the presets in the creator's language, with the same ids", () => {
    const db = createTestDb();
    const f = createFamily(db, { name: "Krug", lang: "de" }, NOW);
    const types = db
      .select()
      .from(calEntryTypes)
      .where(eq(calEntryTypes.familyId, f.id))
      .orderBy(calEntryTypes.position)
      .all();
    expect(types.map((t) => [t.id, t.name])).toEqual([
      ["holiday", "Feiertag"],
      ["vacation", "Urlaub"],
      ["sick", "Krank"],
    ]);
    // Without an editor, nobody's.
    expect(types.map((t) => t.memberUserId)).toEqual([null, null, null]);
  });

  it("deleting a family deletes its calendar", async () => {
    const s = setup();
    const f = newFamily(s);
    await s.call("POST", `/families/${f.id}/entries`, { type: "vacation", date: "2026-08-03" });
    await s.call("POST", `/families/${f.id}/notes`, { icon: "tree", date: "2026-12-25" });
    deleteFamily(s.db, { id: s.owner.id, admin: true }, f.id);
    for (const table of [calEntryTypes, calEntries, calNotes]) {
      expect(s.db.select().from(table).where(eq(table.familyId, f.id)).all()).toEqual([]);
    }
  });
});

describe("calendar API", () => {
  it("adds, removes, sets and clears entries", async () => {
    const { call, ...s } = setup();
    const f = newFamily({ call, ...s });
    const post = (body: unknown) => call("POST", `/families/${f.id}/entries`, body);

    expect((await post({ action: "add", type: "Vacation", from: "2026-08-03", to: "2026-08-09" })).status).toBe(200);
    await post({ action: "add", type: "sick", dates: ["2026-08-04"] });
    let state = (await call("GET", `/families/${f.id}?year=2026`)).data;
    expect(Object.keys(state.entries).length).toBe(7);
    expect(state.entries["2026-08-04"].sort()).toEqual(["sick", "vacation"]);

    await post({
      ops: [
        { action: "remove", type: "vacation", dates: ["2026-08-04"] },
        { action: "set", types: ["holiday"], dates: ["2026-08-05"] },
        { action: "clear", from: "2026-08-08", to: "2026-08-09" },
      ],
    });
    state = (await call("GET", `/families/${f.id}?year=2026`)).data;
    expect(state.entries["2026-08-04"]).toEqual(["sick"]);
    expect(state.entries["2026-08-05"]).toEqual(["holiday"]);
    expect(state.entries["2026-08-08"]).toBeUndefined();
    expect((await call("GET", `/families/${f.id}?year=2025`)).data.entries).toEqual({});
  });

  it("skipWeekends leaves Saturday and Sunday out", async () => {
    const s = setup();
    const f = newFamily(s);
    await s.call("POST", `/families/${f.id}/entries`, {
      action: "add",
      type: "vacation",
      from: "2026-08-03",
      to: "2026-08-16",
      skipWeekends: true,
    });
    const entries = (await s.call("GET", `/families/${f.id}/entries?year=2026`)).data;
    expect(Object.keys(entries).length).toBe(10);
  });

  it("a viewer can read but not write", async () => {
    const s = setup();
    const f = newFamily(s);
    await s.call("POST", `/families/${f.id}/entries`, { type: "vacation", dates: ["2026-01-05"] });
    await s.call("POST", `/families/${f.id}/types`, { name: "Remote", color: "#123456", year: 2026 });

    const state = (await f.view("GET", `/families/${f.id}?year=2026`)).data;
    expect(state.family.readOnly).toBe(true);
    expect(state.family.access).toBe("view");
    expect(state.types.map((t: any) => t.id)).toEqual(["holiday", "vacation", "sick", "remote"]);
    expect(state.entries).toEqual({ "2026-01-05": ["vacation"] });
    expect((await f.view("GET", `/families/${f.id}/entries`)).data).toEqual({ "2026-01-05": ["vacation"] });
    expect((await f.view("GET", `/families/${f.id}/types?year=2026`)).data.length).toBe(4);

    const writes: [string, string, unknown?][] = [
      ["POST", "/entries", { type: "vacation", dates: ["2026-01-02"] }],
      ["PATCH", "", { name: "Hijacked" }],
      ["POST", "/types", { name: "X", color: "#000000" }],
      ["PATCH", "/types/vacation?year=2026", { name: "X" }],
      ["DELETE", "/types/vacation?year=2026"],
      ["POST", "/types/copy", { from: 2026, to: 2027 }],
      ["POST", "/notes", { icon: "tree", date: "2026-12-25" }],
      ["POST", "/import", { format: "family-planner", version: 2, types: [] }],
    ];
    for (const [method, path, body] of writes) {
      const res = await f.view(method, `/families/${f.id}${path}`, body);
      expect([res.status, res.data.error], `${method} ${path}`).toEqual([403, "You can only view this family"]);
    }
    const after = (await s.call("GET", `/families/${f.id}?year=2026`)).data;
    expect(after.family.name).toBe("Krug");
    expect(after.types.length).toBe(4);
    expect(after.entries).toEqual({ "2026-01-05": ["vacation"] });
  });

  it("rejects malformed ids as not found", async () => {
    const s = setup();
    const f = newFamily(s);
    for (const token of ["abc,def.ghij", "aaaaaaaaaa)", `${f.id},read_id.eq.x`, "short"]) {
      const t = encodeURIComponent(token);
      expect((await s.call("GET", `/families/${t}`)).status).toBe(404);
      expect((await s.call("GET", `/families/${t}/entries`)).status).toBe(404);
      expect((await s.call("PATCH", `/families/${t}`, { name: "X" })).status).toBe(404);
      expect((await s.call("POST", `/families/${t}/entries`, { type: "vacation", dates: ["2026-01-02"] })).status).toBe(
        404,
      );
    }
  });

  it("validates input", async () => {
    const s = setup();
    const f = newFamily(s);
    const post = (body: unknown) => s.call("POST", `/families/${f.id}/entries`, body);
    expect((await post({ type: "vacation", dates: ["2026-02-30"] })).status).toBe(400);
    expect((await post({ type: "nope", dates: ["2026-02-03"] })).status).toBe(404);
    expect((await post({ action: "add", dates: ["2026-02-03"] })).status).toBe(400);
    expect((await s.call("GET", "/families/doesnotexist123")).status).toBe(404);
    const foreign = await s.call("POST", `/families/${f.id}/types`, { name: "X", memberId: makeUser(s.db).id });
    expect(foreign.status).toBe(400);
    expect(foreign.data.error).toBe("memberId must be a member of the family");
    expect((await s.call("PATCH", `/families/${f.id}/types/sick`, { memberId: 7 })).status).toBe(400);
    const bad = await s.handler(
      new Request(`${BASE}/families/${f.id}/entries`, {
        method: "POST",
        headers: { authorization: (await authHeader(s)).authorization },
        body: "not json",
      }),
    );
    expect(bad.status).toBe(400);
    expect(await bad.json()).toEqual({ error: "Body must be a JSON object" });
  });

  it("manages entry types", async () => {
    const s = setup();
    const f = newFamily(s);
    const created = await s.call("POST", `/families/${f.id}/types?year=2026`, {
      name: "Day care closed",
      color: "#8B5CF6",
      role: "needs_cover",
    });
    expect(created.status).toBe(201);
    // The caller's type (a color in the body is ignored): their 4th, the 4th shade of blue.
    expect(created.data).toEqual({
      id: "day-care-closed",
      year: 2026,
      name: "Day care closed",
      memberId: s.owner.id,
      color: typeShade(memberColorHex("blue"), 3),
      colorKey: null,
      role: "needs_cover",
      icon: "exclamationmark.triangle",
      position: 3,
      away: false,
      appleSync: true,
      coverOnly: false,
    });
    const nobody = await s.call("POST", `/families/${f.id}/types?year=2026`, { name: "School trip", memberId: null });
    expect(nobody.data).toMatchObject({ memberId: null, color: "#8e8e93" });
    const moved = await s.call("PATCH", `/families/${f.id}/types/school-trip?year=2026`, { memberId: s.owner.id });
    expect(moved.data).toMatchObject({ memberId: s.owner.id, color: typeShade(memberColorHex("blue"), 4) });

    const renamed = await s.call("PATCH", `/families/${f.id}/types/vacation?year=2026`, { name: "Vacation Dad" });
    expect(renamed.data.name).toBe("Vacation Dad");
    // Names work as references too.
    await s.call("POST", `/families/${f.id}/entries`, { type: "vacation dad", dates: ["2026-03-02"] });
    expect((await s.call("GET", `/families/${f.id}/entries`)).data).toEqual({ "2026-03-02": ["vacation"] });

    const deleted = await s.call("DELETE", `/families/${f.id}/types/vacation?year=2026`);
    expect(deleted.data).toEqual({ deleted: "vacation", year: 2026 });
    const state = (await s.call("GET", `/families/${f.id}`)).data;
    expect(state.types.map((t: any) => t.id)).toEqual(["holiday", "sick", "day-care-closed", "school-trip"]);
    // The colors follow: the owner's types are now four, shaded by position.
    expect(state.types.map((t: any) => t.color)).toEqual([0, 1, 2, 3].map((i) => typeShade(memberColorHex("blue"), i)));
    expect(state.entries).toEqual({});
  });

  it("reorders a year's types and keeps some out of Apple Calendar", async () => {
    const s = setup();
    const f = newFamily(s);
    const ids = async () => (await s.call("GET", `/families/${f.id}/types?year=2026`)).data.map((t: any) => t.id);
    expect(await ids()).toEqual(["holiday", "vacation", "sick"]);

    const ordered = await s.call("POST", `/families/${f.id}/types/order?year=2026`, { ids: ["sick", "Holiday", "vacation"] });
    expect(ordered.status).toBe(200);
    expect(ordered.data.map((t: any) => [t.id, t.position])).toEqual([["sick", 0], ["holiday", 1], ["vacation", 2]]);
    expect(await ids()).toEqual(["sick", "holiday", "vacation"]);
    // Every type once, else nothing changes.
    for (const body of [{ ids: ["sick", "holiday"] }, { ids: ["sick", "sick", "vacation"] }, { ids: "sick" }]) {
      expect((await s.call("POST", `/families/${f.id}/types/order?year=2026`, body)).status).toBe(400);
    }
    expect((await s.call("POST", `/families/${f.id}/types/order?year=2026`, { ids: ["sick", "holiday", "nope"] })).status).toBe(404);
    expect((await f.view("POST", `/families/${f.id}/types/order?year=2026`, { ids: ["holiday", "sick", "vacation"] })).status).toBe(403);
    expect(await ids()).toEqual(["sick", "holiday", "vacation"]);

    const off = await s.call("PATCH", `/families/${f.id}/types/sick?year=2026`, { appleSync: false });
    expect(off.data.appleSync).toBe(false);
    expect((await s.call("PATCH", `/families/${f.id}/types/sick?year=2026`, { appleSync: "no" })).status).toBe(400);
    const created = await s.call("POST", `/families/${f.id}/types?year=2026`, { name: "Private", appleSync: false });
    expect(created.data).toMatchObject({ appleSync: false, position: 3 });
    // Copies keep it.
    const copied = await s.call("POST", `/families/${f.id}/types/copy`, { from: 2026, to: 2027 });
    expect(copied.data.map((t: any) => [t.id, t.appleSync])).toEqual([
      ["sick", false], ["holiday", true], ["vacation", true], ["private", false],
    ]);
  });

  it("shows a cover-only type only on the days it covers", async () => {
    const s = setup();
    const f = newFamily(s);
    const on = await s.call("PATCH", `/families/${f.id}/types/vacation?year=2026`, { coverOnly: true });
    expect(on.data.coverOnly).toBe(true);
    expect((await s.call("PATCH", `/families/${f.id}/types/vacation?year=2026`, { coverOnly: "yes" })).status).toBe(400);
    const created = await s.call("POST", `/families/${f.id}/types?year=2026`, { name: "Grandma", role: "covers", coverOnly: true });
    expect(created.data).toMatchObject({ role: "covers", coverOnly: true });
    expect((await s.call("POST", `/families/${f.id}/types?year=2026`, { name: "Kita closed", role: "needs_cover" })).data.coverOnly).toBe(false);
    // Copies and the export file keep it.
    const copied = await s.call("POST", `/families/${f.id}/types/copy`, { from: 2026, to: 2027 });
    expect(copied.data.filter((t: any) => t.coverOnly).map((t: any) => t.id)).toEqual(["vacation", "grandma"]);
    const file = (await s.call("GET", `/families/${f.id}/export`)).data;
    expect(file.types.find((t: any) => t.year === 2026 && t.id === "grandma").coverOnly).toBe(true);
    const target = newFamily(s);
    await s.call("POST", `/families/${target.id}/import`, file);
    const imported = (await s.call("GET", `/families/${target.id}/types?year=2026`)).data;
    expect(imported.find((t: any) => t.id === "grandma").coverOnly).toBe(true);

    // Only the app's cells hide the days it doesn't cover: the API and the overview keep them.
    await s.call("POST", `/families/${f.id}/entries`, {
      ops: [
        { type: "grandma", from: "2026-03-02", to: "2026-03-06" },
        { type: "kita-closed", dates: ["2026-03-04", "2026-03-05"] },
      ],
    });
    expect((await s.call("GET", `/families/${f.id}/entries?year=2026`)).data["2026-03-02"]).toEqual(["grandma"]);
    const summary = await calendarSummary(s.db, f.id, "2026-03-01");
    expect(summary.nextGap).toBeNull();
    expect(summary.upcoming.filter((u) => u.name === "Grandma").map((u) => [u.from, u.to])).toEqual([["2026-03-02", "2026-03-06"]]);
  });

  it("gives entry types an icon: their own or their role's", async () => {
    const s = setup();
    const f = newFamily(s);
    const types = `/families/${f.id}/types`;
    // The presets: Holiday the role's, Vacation and Sick their own.
    const listed = (await s.call("GET", `${types}?year=2026`)).data;
    expect(listed.map((t: any) => [t.id, t.icon])).toEqual([
      ["holiday", "sun.max"],
      ["vacation", "beach.umbrella"],
      ["sick", "cross.case"],
    ]);

    // Without one (or null), the role's, which follows the role.
    const roles = { none: "tag", needs_cover: "exclamationmark.triangle", covers: "checkmark.shield", day_off: "sun.max" };
    for (const [role, icon] of Object.entries(roles)) {
      const res = await s.call("POST", `${types}?year=2027`, { name: `T ${role}`, role, icon: role === "none" ? null : undefined });
      expect([res.status, res.data.icon]).toEqual([201, icon]);
    }
    const plain = await s.call("PATCH", `${types}/t-none?year=2027`, { role: "covers" });
    expect(plain.data.icon).toBe("checkmark.shield");

    // Its own: kept through other changes, null resets it to the role's.
    const own = await s.call("POST", `${types}?year=2026`, { name: "Trip", icon: "airplane" });
    expect([own.status, own.data.icon]).toEqual([201, "airplane"]);
    expect((await s.call("PATCH", `${types}/trip?year=2026`, { name: "Trips", role: "covers" })).data.icon).toBe("airplane");
    expect((await s.call("PATCH", `${types}/trip?year=2026`, { icon: "car.fill" })).data.icon).toBe("car.fill");
    const reset = await s.call("PATCH", `${types}/trip?year=2026`, { icon: null });
    expect(reset.data.icon).toBe("checkmark.shield");
    const row = s.db.select().from(calEntryTypes).where(eq(calEntryTypes.id, "trip")).get()!;
    expect(row.icon).toBeNull();

    // Only SF Symbol names; nothing is written otherwise.
    for (const icon of ["🏖", "Airplane", "car fill", "car..fill", ".car", "car.", "", 7, "a".repeat(65)]) {
      const added = await s.call("POST", `${types}?year=2026`, { name: "Bad", icon });
      expect([added.status, added.data.error]).toEqual([400, "icon must be an SF Symbol name"]);
      const changed = await s.call("PATCH", `${types}/sick?year=2026`, { icon });
      expect([changed.status, changed.data.error]).toEqual([400, "icon must be an SF Symbol name"]);
    }
    expect((await s.call("POST", `${types}?year=2026`, { name: "Long", icon: "a".repeat(64) })).status).toBe(201);
    expect((await s.call("GET", `${types}?year=2026`)).data.find((t: any) => t.id === "sick").icon).toBe("cross.case");

    // Copying a year keeps the icons, own and role's.
    s.db.delete(calEntryTypes).where(eq(calEntryTypes.year, 2027)).run();
    const copied = await s.call("POST", `${types}/copy`, { from: 2026, to: 2027 });
    expect(copied.data.map((t: any) => [t.id, t.icon])).toEqual(
      (await s.call("GET", `${types}?year=2026`)).data.map((t: any) => [t.id, t.icon]),
    );
    const copiedRows = s.db.select().from(calEntryTypes).where(eq(calEntryTypes.year, 2027)).all();
    expect(Object.fromEntries(copiedRows.map((t) => [t.id, t.icon]))).toMatchObject({ holiday: null, trip: null, sick: "cross.case" });
  });

  it("renames a family", async () => {
    const s = setup();
    const f = newFamily(s);
    const res = await s.call("PATCH", `/families/${f.id}`, { name: "Our family" });
    expect(res.status).toBe(200);
    expect(res.data.family.name).toBe("Our family");
    expect(res.data.family.id).toBe(f.id);
    expect(res.data.family.readOnly).toBe(false);
    expect(res.data.types.length).toBe(3);
    expect((await f.view("GET", `/families/${f.id}`)).data.family.name).toBe("Our family");
    expect((await s.call("PATCH", `/families/${f.id}`, { name: " " })).status).toBe(400);
  });

  it("sets, replaces and clears day notes", async () => {
    const s = setup();
    const f = newFamily(s);
    const post = (body: unknown) => s.call("POST", `/families/${f.id}/notes`, body);

    let res = await post({ icon: " tree ", comment: " Christmas ", from: "2026-12-24", to: "2026-12-26" });
    expect(res.status).toBe(200);
    expect(res.data).toEqual({ ok: true, ops: 1, days: 3 });
    expect((await s.call("GET", `/families/${f.id}/notes?year=2026`)).data).toEqual({
      "2026-12-24": { icon: "tree", comment: "Christmas" },
      "2026-12-25": { icon: "tree", comment: "Christmas" },
      "2026-12-26": { icon: "tree", comment: "Christmas" },
    });

    res = await post({
      ops: [
        // "set" replaces the whole note: no comment given means "".
        { action: "set", icon: "gift", dates: ["2026-12-24"] },
        { action: "clear", date: "2026-12-26" },
        // Both empty after trimming behaves like "clear".
        { icon: " ", comment: "", date: "2026-12-25" },
        { comment: "Easter", from: "2026-04-03", to: "2026-04-06" },
      ],
    });
    expect(res.data).toEqual({ ok: true, ops: 4, days: 7 });
    const notes = (await s.call("GET", `/families/${f.id}/notes?from=2026-12-01&to=2026-12-31`)).data;
    expect(notes).toEqual({ "2026-12-24": { icon: "gift", comment: "" } });
    expect(Object.keys((await s.call("GET", `/families/${f.id}/notes?year=2026`)).data).length).toBe(5);
    expect((await s.call("GET", `/families/${f.id}/notes?year=2025`)).data).toEqual({});
  });

  it("note ops skip weekends like entry ops", async () => {
    const s = setup();
    const f = newFamily(s);
    const res = await s.call("POST", `/families/${f.id}/notes`, {
      icon: "beach.umbrella",
      from: "2026-08-03",
      to: "2026-08-16",
      skipWeekends: true,
    });
    expect(res.data.days).toBe(10);
    const notes = (await s.call("GET", `/families/${f.id}/notes`)).data;
    expect(Object.keys(notes).length).toBe(10);
    expect(notes["2026-08-08"]).toBeUndefined();
  });

  it("family state includes notes for the requested range", async () => {
    const s = setup();
    const f = newFamily(s);
    await s.call("POST", `/families/${f.id}/notes`, {
      ops: [
        { icon: "tree", comment: "Christmas", date: "2026-12-25" },
        { icon: "sparkles", date: "2025-12-31" },
      ],
    });
    const state = (await s.call("GET", `/families/${f.id}?year=2026`)).data;
    expect(state.notes).toEqual({ "2026-12-25": { icon: "tree", comment: "Christmas" } });
    // Viewers read notes too.
    const view = (await f.view("GET", `/families/${f.id}?from=2025-12-01&to=2025-12-31`)).data;
    expect(view.notes).toEqual({ "2025-12-31": { icon: "sparkles", comment: "" } });
    expect(Object.keys((await f.view("GET", `/families/${f.id}/notes`)).data)).toEqual(["2025-12-31", "2026-12-25"]);
  });

  it("notes and entries are independent", async () => {
    const s = setup();
    const f = newFamily(s);
    await s.call("POST", `/families/${f.id}/entries`, { type: "holiday", date: "2026-12-25" });
    await s.call("POST", `/families/${f.id}/notes`, { comment: "Christmas", date: "2026-12-25" });

    await s.call("POST", `/families/${f.id}/entries`, { action: "clear", date: "2026-12-25" });
    let state = (await s.call("GET", `/families/${f.id}?year=2026`)).data;
    expect(state.entries).toEqual({});
    expect(state.notes).toEqual({ "2026-12-25": { icon: "", comment: "Christmas" } });

    await s.call("POST", `/families/${f.id}/entries`, { type: "holiday", date: "2026-12-25" });
    await s.call("POST", `/families/${f.id}/notes`, { action: "clear", date: "2026-12-25" });
    state = (await s.call("GET", `/families/${f.id}?year=2026`)).data;
    expect(state.entries).toEqual({ "2026-12-25": ["holiday"] });
    expect(state.notes).toEqual({});
  });

  it("validates note ops", async () => {
    const s = setup();
    const f = newFamily(s);
    const post = (body: unknown) => s.call("POST", `/families/${f.id}/notes`, body);
    const cases: [unknown, string][] = [
      [{ action: "add", icon: "tree", date: "2026-12-25" }, "action must be set or clear"],
      [{ date: "2026-12-25" }, '"set" needs "icon" or "comment"'],
      [{ icon: 1, date: "2026-12-25" }, "icon must be an SF Symbol name"],
      [{ comment: null, date: "2026-12-25" }, "comment must be a string"],
      // Icons are SF Symbol names: no emoji, capitals, spaces or stray dots, at most 64.
      ...["🎄", "Star", "sun max", "sun..max", ".sun", "sun.", "a".repeat(65)].map(
        (icon): [unknown, string] => [{ icon, date: "2026-12-25" }, "icon must be an SF Symbol name"],
      ),
      [{ comment: "x".repeat(501), date: "2026-12-25" }, "comment is too long (max. 500)"],
      [{ icon: "tree", dates: ["2026-02-30"] }, 'Invalid date "2026-02-30" (use YYYY-MM-DD)'],
      [{ icon: "tree", dates: "2026-12-25" }, "dates must be an array"],
      [{ icon: "tree", from: "2026-12-25", to: "nope" }, "from/to must be YYYY-MM-DD"],
      [{ icon: "tree" }, 'Op needs "dates" or "from"/"to"'],
      [{ ops: [1] }, "Each op must be an object"],
      [{ icon: "tree", from: "2020-01-01", to: "2026-12-31" }, "Range is too long"],
      [
        { ops: [1, 2, 3, 4].map((y) => ({ icon: "tree", from: `202${y}-01-01`, to: `202${y + 2}-12-31` })) },
        "Too many days in one request",
      ],
    ];
    for (const [body, error] of cases) {
      const res = await post(body);
      expect([res.status, res.data.error]).toEqual([400, error]);
    }
    // Limits are inclusive.
    const ok = await post({ icon: "a".repeat(64), comment: "x".repeat(500), date: "2026-10-03" });
    expect(ok.status).toBe(200);
    // Nothing was written by the failed requests.
    expect(Object.keys((await s.call("GET", `/families/${f.id}/notes`)).data)).toEqual(["2026-10-03"]);
  });

  it("every year has its own entry types", async () => {
    const s = setup();
    const f = newFamily(s);
    const types = `/families/${f.id}/types`;
    const state = (year: number) => s.call("GET", `/families/${f.id}?year=${year}`);

    // A year without types of its own has none, and its days can't use other years' types.
    expect((await state(2027)).data.types).toEqual([]);
    expect((await state(2027)).data.typeYears).toEqual([2026]);
    const missing = await s.call("POST", `/families/${f.id}/entries`, { type: "vacation", dates: ["2027-01-04"] });
    expect([missing.status, missing.data.error]).toEqual([404, 'Unknown entry type "vacation" in 2027']);

    // Copying keeps ids, names, colors, roles and order.
    const copied = await s.call("POST", `${types}/copy`, { from: 2026, to: 2027 });
    expect(copied.status).toBe(200);
    expect(copied.data.map((t: any) => [t.id, t.year, t.position])).toEqual([
      ["holiday", 2027, 0],
      ["vacation", 2027, 1],
      ["sick", 2027, 2],
    ]);
    expect((await state(2027)).data.typeYears).toEqual([2026, 2027]);

    // Changes stay within their year.
    await s.call("PATCH", `${types}/vacation?year=2027`, { name: "Vacation Mom", color: "#0ea5e9" });
    await s.call("POST", types, { name: "Day care closed", color: "#8b5cf6", year: 2027 });
    await s.call("DELETE", `${types}/sick?year=2026`);
    expect((await s.call("GET", `${types}?year=2026`)).data.map((t: any) => t.name)).toEqual(["Holiday", "Vacation"]);
    expect((await s.call("GET", `${types}?year=2027`)).data.map((t: any) => t.name)).toEqual([
      "Holiday",
      "Vacation Mom",
      "Sick",
      "Day care closed",
    ]);

    // A copy only adds what the target year doesn't have yet.
    const again = await s.call("POST", `${types}/copy`, { from: 2027, to: 2026 });
    expect(again.data.map((t: any) => [t.id, t.name])).toEqual([
      ["holiday", "Holiday"],
      ["vacation", "Vacation"],
      ["sick", "Sick"],
      ["day-care-closed", "Day care closed"],
    ]);

    // Without a year filter, the state has the types of every year.
    expect((await s.call("GET", `/families/${f.id}`)).data.types.length).toBe(8);
    expect((await s.call("GET", `/families/${f.id}?from=2026-12-01&to=2027-01-31`)).data.types.length).toBe(8);
    expect((await s.call("GET", `/families/${f.id}?year=2028`)).data.types).toEqual([]);

    const errors: [unknown, number, string][] = [
      [{ from: 2025, to: 2026 }, 404, "2025 has no entry types"],
      [{ from: "26", to: 2027 }, 400, "from must be YYYY"],
      [{ from: 2026 }, 400, "to must be YYYY"],
    ];
    for (const [body, status, error] of errors) {
      const res = await s.call("POST", `${types}/copy`, body);
      expect([res.status, res.data.error]).toEqual([status, error]);
    }
    expect((await s.call("GET", `${types}?year=nope`)).status).toBe(400);
  });

  it("resolves type references per year of each day", async () => {
    const s = setup();
    const f = newFamily(s);
    await s.call("POST", `/families/${f.id}/types`, { name: "Urlaub", color: "#22c55e", year: 2027 });
    // "Urlaub" is "vacation" in 2026 (renamed) and "urlaub" in 2027.
    await s.call("PATCH", `/families/${f.id}/types/vacation?year=2026`, { name: "Urlaub" });
    const res = await s.call("POST", `/families/${f.id}/entries`, {
      type: "urlaub",
      from: "2026-12-31",
      to: "2027-01-01",
    });
    expect(res.data).toEqual({ ok: true, ops: 1, days: 2 });
    expect((await s.call("GET", `/families/${f.id}/entries`)).data).toEqual({
      "2026-12-31": ["vacation"],
      "2027-01-01": ["urlaub"],
    });

    // Deleting a type removes only its own year's entries.
    await s.call("POST", `/families/${f.id}/types/copy`, { from: 2026, to: 2027 });
    await s.call("POST", `/families/${f.id}/entries`, { type: "vacation", date: "2027-01-04" });
    await s.call("DELETE", `/families/${f.id}/types/vacation?year=2027`);
    expect((await s.call("GET", `/families/${f.id}/entries`)).data).toEqual({
      "2026-12-31": ["vacation"],
      "2027-01-01": ["urlaub"],
    });
  });

  it("exports a family's calendar and imports the file over another one", async () => {
    const s = setup();
    const f = newFamily(s);
    await s.call("POST", `/families/${f.id}/types/copy`, { from: 2026, to: 2027 });
    await s.call("PATCH", `/families/${f.id}/types/sick?year=2027`, { name: "Ill", position: 7, icon: "thermometer", appleSync: false });
    await s.call("POST", `/families/${f.id}/entries`, {
      ops: [
        { types: ["vacation", "sick"], dates: ["2026-08-03"] },
        { type: "holiday", dates: ["2027-01-01"] },
      ],
    });
    await s.call("POST", `/families/${f.id}/notes`, { icon: "tree", comment: "Xmas", date: "2026-12-25" });

    // Viewers may export; the file never contains the family's ids.
    const res = await f.view("GET", `/families/${f.id}/export`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-disposition")).toBe('attachment; filename="krug.json"');
    const file = res.data;
    expect([file.format, file.version, file.name]).toEqual(["family-planner", 2, "Krug"]);
    expect(file.types.length).toBe(6);
    // Types carry their stored icon: their own, or null for the role's.
    const iconOf = (year: number, id: string) => file.types.find((t: any) => t.year === year && t.id === id).icon;
    expect([iconOf(2026, "holiday"), iconOf(2026, "vacation"), iconOf(2027, "sick")]).toEqual([null, "beach.umbrella", "thermometer"]);
    expect(file.entries).toEqual({ "2026-08-03": ["sick", "vacation"], "2027-01-01": ["holiday"] });
    expect(file.notes).toEqual({ "2026-12-25": { icon: "tree", comment: "Xmas" } });
    const text = JSON.stringify(file);
    expect(text.includes(f.id)).toBe(false);

    // Importing replaces everything of the target, but keeps its name.
    const target = newFamily(s);
    s.db.update(families).set({ name: "Other" }).where(eq(families.id, target.id)).run();
    await s.call("POST", `/families/${target.id}/types?year=2028`, { name: "Gone", color: "#000000" });
    await s.call("POST", `/families/${target.id}/entries`, { type: "gone", date: "2028-03-01" });
    await s.call("POST", `/families/${target.id}/notes`, { icon: "moon", date: "2028-03-02" });
    const imported = await s.call("POST", `/families/${target.id}/import?year=2027`, file);
    expect(imported.status).toBe(200);
    expect(imported.data.family.id).toBe(target.id);
    expect(imported.data.family.name).toBe("Other");
    expect(imported.data.typeYears).toEqual([2026, 2027]);
    expect(imported.data.entries).toEqual({ "2027-01-01": ["holiday"] });

    const all = (await s.call("GET", `/families/${target.id}`)).data;
    const original = (await s.call("GET", `/families/${f.id}`)).data;
    expect(all.types).toEqual(original.types);
    expect(all.entries).toEqual(original.entries);
    expect(all.notes).toEqual(original.notes);
    expect((await s.call("GET", `/families/${target.id}/export`)).data.types).toEqual(file.types);
  });

  it("import needs an editor and validates the file", async () => {
    const s = setup();
    const f = newFamily(s);
    const type = { year: 2026, id: "vacation", name: "Vacation", color: "#22c55e", role: "covers" };
    const file = { format: "vacation-planner", version: 1, name: "Imported", types: [type] };
    const path = `/families/${f.id}/import`;
    const status = async (body: unknown) => (await s.call("POST", path, body)).status;

    expect((await f.view("POST", path, file)).status).toBe(403);
    expect((await s.call("POST", "/families/unknownToken123/import", file)).status).toBe(404);
    expect((await s.call("GET", path)).status).toBe(405);
    expect(await status({ ...file, format: "other" })).toBe(400);
    expect(await status({ ...file, version: 3 })).toBe(400);
    expect(await status({ ...file, types: {} })).toBe(400);
    expect(await status({ ...file, types: [type, type] })).toBe(400);
    expect(await status({ ...file, types: [{ ...type, id: "../x" }] })).toBe(400);
    expect(await status({ ...file, types: [{ ...type, role: "boss" }] })).toBe(400);
    expect(await status({ ...file, types: [{ ...type, year: 26 }] })).toBe(400);
    expect(await status({ ...file, types: [{ ...type, icon: "🏖" }] })).toBe(400);
    // Entries can only use the types of their own year.
    expect(await status({ ...file, entries: { "2027-08-03": ["vacation"] } })).toBe(400);
    expect(await status({ ...file, entries: { "2026-02-30": ["vacation"] } })).toBe(400);
    expect(await status({ ...file, entries: { "2026-08-03": "vacation" } })).toBe(400);
    expect(await status({ ...file, entries: { "2026-08-03": [1] } })).toBe(400);
    expect(await status({ ...file, notes: { "2026-12-25": "tree" } })).toBe(400);
    expect(await status({ ...file, notes: { "2026-12-25": { comment: "x".repeat(501) } } })).toBe(400);

    // A rejected file changes nothing.
    const before = (await s.call("GET", `/families/${f.id}`)).data;
    expect(before.types.map((t: any) => t.id)).toEqual(["holiday", "vacation", "sick"]);

    // Empty notes are dropped.
    const res = await s.call("POST", `${path}?year=2026`, {
      ...file,
      entries: { "2026-08-03": ["vacation"] },
      notes: {
        "2026-12-24": { icon: "", comment: " " },
        "2026-12-25": { icon: "gift" },
        // An older file's emoji icon goes to the front of the comment.
        "2026-12-26": { icon: "🎄", comment: "Boxing Day" },
        "2026-12-27": { icon: "🎄" },
        "2026-12-28": { icon: "🎄", comment: "x".repeat(500) },
      },
    });
    expect(res.status).toBe(200);
    expect(res.data.entries).toEqual({ "2026-08-03": ["vacation"] });
    // A type without an icon (an older file) gets its role's.
    expect(res.data.types.map((t: any) => t.icon)).toEqual(["checkmark.shield"]);
    expect(res.data.notes).toEqual({
      "2026-12-25": { icon: "gift", comment: "" },
      "2026-12-26": { icon: "", comment: "🎄 Boxing Day" },
      "2026-12-27": { icon: "", comment: "🎄" },
      "2026-12-28": { icon: "", comment: `🎄 ${"x".repeat(497)}` },
    });
  });

  it("a failed replace leaves the calendar as it was", async () => {
    const s = setup();
    const f = newFamily(s);
    await s.call("POST", `/families/${f.id}/entries`, { type: "vacation", date: "2026-08-03" });
    const store = new DrizzleCalendarStore(s.db);
    // An entry of a type that doesn't exist breaks the foreign key: nothing changes.
    await expect(store.replaceContents(f.id, [], [{ day: "2026-08-04", type_id: "nope" }], [])).rejects.toThrow();
    expect((await s.call("GET", `/families/${f.id}/entries`)).data).toEqual({ "2026-08-03": ["vacation"] });
    expect((await store.listTypes(f.id)).length).toBe(3);
  });
});

async function authHeader(s: ReturnType<typeof setup>) {
  return { authorization: `Bearer ${s.apiToken(s.owner.id)}` };
}

describe("family API access", () => {
  it("each member only gets what their role allows", async () => {
    const s = setup();
    const f = newFamily(s);
    const edit = (await s.call("GET", `/families/${f.id}`)).data.family;
    expect(edit.access).toBe("edit");
    expect(edit.id).toBe(f.id);
    expect(edit).not.toHaveProperty("feedId");

    const view = (await f.view("GET", `/families/${f.id}`)).data.family;
    expect([view.access, view.readOnly]).toEqual(["view", true]);
    expect(view.id).toBe(f.id);
  });

  it("everything needs signing in", async () => {
    const s = setup();
    const f = newFamily(s);
    const anon = s.as(null);
    for (const path of ["", "/entries", "/types", "/notes", "/export"]) {
      const res = await anon("GET", `/families/${f.id}${path}`);
      expect([res.status, res.data.error], path).toEqual([401, "Sign in first"]);
    }
    expect((await anon("POST", `/families/${f.id}/entries`, { type: "x" })).status).toBe(401);
    // There is no calendar feed (any more).
    expect((await anon("GET", `/families/${f.id}/calendar.ics`)).status).toBe(404);
    expect((await s.call("GET", `/families/${f.id}/calendar.ics`)).status).toBe(404);
    expect((await s.call("POST", `/families/${f.id}/links`, { link: "feed" })).status).toBe(404);
    // A wrong or ended token says so.
    const bad = await s.as("ohana_nonsense")("GET", `/families/${f.id}`);
    expect([bad.status, bad.data.error]).toEqual([401, "Your session has ended, sign in again"]);
  });

  it("families of others look like no family at all, also to administrators", async () => {
    const s = setup();
    const other = makeUser(s.db, { email: "other@test" });
    const family = makeFamily(s.db, other.id); // the owner (an admin) isn't a member
    expect((await s.call("GET", `/families/${family.id}`)).status).toBe(404);
    expect((await s.call("PATCH", `/families/${family.id}`, { name: "Mine" })).status).toBe(404);
    expect(
      (await s.call("POST", `/families/${family.id}/entries`, { type: "vacation", date: "2026-01-05" })).status,
    ).toBe(404);
  });

  it("the session cookie works too, but writes only from the app's own pages", async () => {
    const s = setup();
    const f = newFamily(s);
    const session = createToken(s.db, { userId: s.owner.id, kind: "session" }, NOW).token;
    const cookie = s.request({ cookie: `other=1; ${SESSION_COOKIE}=${session}` });
    expect((await cookie("GET", `/families/${f.id}?year=2026`)).data.family.access).toBe("edit");

    const body = { type: "vacation", date: "2026-08-03" };
    const cross = await cookie("POST", `/families/${f.id}/entries`, body, {
      "sec-fetch-site": "cross-site",
      origin: "https://evil.test",
    });
    expect(cross.status).toBe(403);
    const same = await cookie("POST", `/families/${f.id}/entries`, body, { "sec-fetch-site": "same-origin" });
    expect(same.status).toBe(200);
    expect((await cookie("GET", `/families/${f.id}/entries`)).data).toEqual({ "2026-08-03": ["vacation"] });
  });

  it("accounts that still have to set a password can't use the API", async () => {
    const s = setup();
    const f = newFamily(s);
    const pending = makeUser(s.db, { onboardingStep: "SET_CREDENTIALS" });
    s.db.insert(familyMembers).values({ familyId: f.id, userId: pending.id, role: "editor", joinedAt: NOW }).run();
    const res = await s.as(s.apiToken(pending.id))("GET", `/families/${f.id}`);
    expect(res.status).toBe(403);
  });

  it("answers CORS preflight and unknown paths", async () => {
    const s = setup();
    const f = newFamily(s);
    const pre = await s.handler(new Request(`${BASE}/families/${f.id}/entries`, { method: "OPTIONS" }));
    expect(pre.status).toBe(204);
    expect(pre.headers.get("access-control-allow-origin")).toBe("*");
    expect((await s.call("GET", `/families/${f.id}/nope`)).status).toBe(404);
    expect((await s.call("PUT", `/families/${f.id}`)).status).toBe(405);
  });
});

describe("calendar summary", () => {
  it("finds the next uncovered weekday and what comes up", async () => {
    const s = setup();
    const f = newFamily(s);
    await s.call("POST", `/families/${f.id}/types`, {
      name: "Kita zu",
      color: "#8b5cf6",
      role: "needs_cover",
      year: 2026,
    });
    await s.call("POST", `/families/${f.id}/entries`, {
      ops: [
        { type: "vacation", from: "2026-10-28", to: "2026-11-03" }, // started before "today"
        { type: "kita-zu", from: "2026-11-02", to: "2026-11-06" }, // Mon–Fri, covered Mon + Tue
        { type: "holiday", date: "2026-12-25" },
        { type: "sick", date: "2026-09-01" }, // over
      ],
    });
    const summary = await calendarSummary(s.db, f.id, "2026-11-01");
    expect(summary.nextGap).toBe("2026-11-04");
    expect(summary.upcoming.map((u) => [u.name, u.from, u.to])).toEqual([
      ["Vacation", "2026-10-28", "2026-11-03"],
      ["Kita zu", "2026-11-02", "2026-11-06"],
      ["Holiday", "2026-12-25", "2026-12-25"],
    ]);
    expect(summary.upcoming[0].member).toEqual({ id: s.owner.id, name: s.owner.name.trim() || "owner", color: "blue", photo: null });
    expect(summary.upcoming[0].color).toBe(typeShade(memberColorHex("blue"), 1));
    expect((await calendarSummary(s.db, f.id, "2026-11-07")).nextGap).toBeNull();
  });
});
