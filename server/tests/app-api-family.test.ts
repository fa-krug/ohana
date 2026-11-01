// The native app's family routes (lib/families/app-routes.ts): the overview and the household
// settings, signed in with API tokens, and creating a family (POST /api/v1/families).

import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { calEntryTypes, familyMembers, families, familyPeople, notificationChannels, users } from "@/lib/db/schema";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { handleFamily } from "@/lib/calendar/family-routes";
import { handleCalendar } from "@/lib/calendar/vacation";
import { createFamilyForUser, handleFamilyApp } from "@/lib/families/app-routes";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const BASE = "http://ohana.test/api/v1";

type Res = { status: number; data: any };

function setup() {
  const db = createTestDb();
  const handler = createFamilyApi([handleFamilyApp, handleFamily, handleCalendar], {
    db,
    appUrl: "http://ohana.test",
    now: () => NOW,
  });
  const as =
    (userId: string) =>
    async (method: string, path: string, body?: unknown): Promise<Res> => {
      const token = createToken(db, { userId, kind: "api" }, NOW).token;
      const res = await handler(
        new Request(BASE + path, {
          method,
          headers: { authorization: `Bearer ${token}`, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
          body: body !== undefined ? JSON.stringify(body) : undefined,
        }),
      );
      const text = await res.text();
      return { status: res.status, data: text ? JSON.parse(text) : null };
    };
  const editor = makeUser(db, { email: "anna@test", name: "Anna" });
  const viewer = makeUser(db, { email: "ben@test", name: "Ben" });
  const outsider = makeUser(db, { email: "eve@test" });
  const family = makeFamily(db, editor.id, [{ userId: viewer.id, role: "viewer" }]);
  const f = `/families/${family.id}`;
  return { db, family, f, editor, viewer, outsider, asEditor: as(editor.id), asViewer: as(viewer.id), asOutsider: as(outsider.id), as };
}

describe("GET /overview", () => {
  it("answers the dashboard for the app's day", async () => {
    const s = setup();
    s.db.update(familyMembers).set({ birthday: "1990-11-20" }).where(eq(familyMembers.userId, s.editor.id)).run();
    const res = await s.asViewer("GET", `${s.f}/overview?today=2026-11-02`);
    expect(res.status).toBe(200);
    expect(res.data.today).toBe("2026-11-02");
    expect(Object.keys(res.data).sort()).toEqual(
      ["awayToday", "birthdays", "calendar", "finance", "meals", "searches", "today", "todayEvents", "upcoming"].sort(),
    );
    expect(res.data.birthdays).toEqual([{ day: "2026-11-20", name: "Anna", age: 36 }]);
    expect(res.data.finance).toMatchObject({ month: "2026-11", incomeCents: 0, expenseCents: 0, count: 0, balanceCents: null });
    expect(res.data.meals).toEqual({ today: null });
    expect(res.data.calendar).toHaveProperty("nextGap");
  });

  it("uses the server's day for a missing or odd day, and hides the family from others", async () => {
    const s = setup();
    expect((await s.asEditor("GET", `${s.f}/overview?today=nope`)).data.today).toBe("2026-11-01");
    expect((await s.asOutsider("GET", `${s.f}/overview`)).status).toBe(404);
    expect((await s.asEditor("POST", `${s.f}/overview`)).status).toBe(405);
  });
});

describe("GET /household", () => {
  it("shows members, people, invites, home, channels and events to editors", async () => {
    const s = setup();
    await s.asEditor("POST", `${s.f}/household/invites`, { role: "viewer" });
    const res = await s.asEditor("GET", `${s.f}/household`);
    expect(res.status).toBe(200);
    expect(res.data).toMatchObject({ name: "Krug", role: "editor", selfId: s.editor.id, people: [], channels: [] });
    expect(res.data.home).toEqual({ address: null, lat: null, lng: null });
    expect(res.data.members.map((m: any) => [m.email, m.role, m.birthday])).toEqual([
      ["anna@test", "editor", null],
      ["ben@test", "viewer", null],
    ]);
    expect(res.data.invites).toHaveLength(1);
    expect(res.data.invites[0].url).toMatch(/^http:\/\/ohana\.test\/invite\/.+/);
    expect(res.data.events.map((e: any) => [e.event, e.enabled, e.channelIds, e.hasChannels])).toEqual([
      ["appointment_found", true, null, false],
      ["coverage_gap", true, null, true],
      ["assistant_turn_finished", false, null, true],
    ]);
  });

  it("gives viewers no invites and refuses their changes", async () => {
    const s = setup();
    await s.asEditor("POST", `${s.f}/household/invites`, { role: "viewer" });
    const res = await s.asViewer("GET", `${s.f}/household`);
    expect(res.data.role).toBe("viewer");
    expect(res.data.invites).toEqual([]);
    expect((await s.asViewer("POST", `${s.f}/household/people`, { name: "Mia" })).status).toBe(403);
    expect((await s.asViewer("PUT", `${s.f}/household/home`, { address: "x", lat: 1, lng: 2 })).status).toBe(403);
    expect((await s.asViewer("PATCH", `${s.f}/household/members/${s.editor.id}`, { role: "viewer" })).status).toBe(403);
    expect((await s.asOutsider("GET", `${s.f}/household`)).status).toBe(404);
    expect((await s.asEditor("GET", `${s.f}/household/nothing`)).status).toBe(404);
  });
});

describe("members", () => {
  it("adds an account by email and changes roles, keeping an editor", async () => {
    const s = setup();
    const carl = makeUser(s.db, { email: "carl@test" });
    const added = await s.asEditor("POST", `${s.f}/household/members`, { email: "CARL@test", role: "viewer" });
    expect(added.status).toBe(201);
    expect(added.data).toMatchObject({ userId: carl.id, role: "viewer" });
    expect((await s.asEditor("POST", `${s.f}/household/members`, { email: "nobody@test", role: "viewer" })).status).toBe(404);

    const promoted = await s.asEditor("PATCH", `${s.f}/household/members/${s.viewer.id}`, { role: "editor" });
    expect(promoted.data.role).toBe("editor");
    // Anna steps down: Ben is still an editor.
    expect((await s.asEditor("PATCH", `${s.f}/household/members/${s.editor.id}`, { role: "viewer" })).status).toBe(200);
    // Ben can't step down now.
    const last = await s.as(s.viewer.id)("PATCH", `${s.f}/household/members/${s.viewer.id}`, { role: "viewer" });
    expect(last.status).toBe(400);
    expect(last.data.error).toMatch(/editor/);
  });

  it("lets members set their own birthday, editors anyone's", async () => {
    const s = setup();
    const own = await s.asViewer("PATCH", `${s.f}/household/members/${s.viewer.id}`, { birthday: "2001-02-03" });
    expect(own.status).toBe(200);
    expect(own.data.birthday).toBe("2001-02-03");
    expect((await s.asViewer("PATCH", `${s.f}/household/members/${s.editor.id}`, { birthday: "1990-01-01" })).status).toBe(403);
    const cleared = await s.asEditor("PATCH", `${s.f}/household/members/${s.viewer.id}`, { birthday: null });
    expect(cleared.data.birthday).toBeNull();
    expect((await s.asEditor("PATCH", `${s.f}/household/members/${s.viewer.id}`, { birthday: "2999-01-01" })).status).toBe(400);
  });

  it("lets a member leave, and editors remove others", async () => {
    const s = setup();
    expect((await s.asViewer("DELETE", `${s.f}/household/members/${s.editor.id}`)).status).toBe(403);
    expect((await s.asViewer("DELETE", `${s.f}/household/members/${s.viewer.id}`)).status).toBe(200);
    expect(s.db.select().from(familyMembers).where(eq(familyMembers.familyId, s.family.id)).all()).toHaveLength(1);
    // The only member deletes the family instead.
    expect((await s.asEditor("DELETE", `${s.f}/household/members/${s.editor.id}`)).status).toBe(400);
  });
});

describe("people and invites", () => {
  it("adds, edits and removes someone without an account, optionally with an invite", async () => {
    const s = setup();
    const added = await s.asEditor("POST", `${s.f}/household/people`, { name: "Mia", birthday: "2018-05-04", invite: "viewer" });
    expect(added.status).toBe(201);
    expect(added.data.person).toMatchObject({ name: "Mia", birthday: "2018-05-04" });
    expect(added.data.invite.url).toBe(`http://ohana.test/invite/${added.data.invite.code}`);
    const id = added.data.person.id;
    expect((await s.asEditor("POST", `${s.f}/household/people`, { name: "mia" })).status).toBe(409);

    const edited = await s.asEditor("PATCH", `${s.f}/household/people/${id}`, { name: "Mia K.", birthday: "" });
    expect(edited.data).toEqual({ id, name: "Mia K.", birthday: null });
    const household = (await s.asEditor("GET", `${s.f}/household`)).data;
    expect(household.people).toEqual([{ id, name: "Mia K.", birthday: null }]);
    expect(household.invites[0].personId).toBe(id);

    expect((await s.asEditor("DELETE", `${s.f}/household/people/${id}`)).status).toBe(200);
    expect(s.db.select().from(familyPeople).all()).toEqual([]);
    expect((await s.asEditor("DELETE", `${s.f}/household/people/${id}`)).status).toBe(404);
  });

  it("creates an invite for a person and revokes invites", async () => {
    const s = setup();
    const person = (await s.asEditor("POST", `${s.f}/household/people`, { name: "Opa" })).data.person;
    expect((await s.asEditor("GET", `${s.f}/household`)).data.invites).toEqual([]);
    const invite = await s.asEditor("POST", `${s.f}/household/invites`, { role: "editor", personId: person.id });
    expect(invite.status).toBe(201);
    expect(invite.data.url).toContain(invite.data.code);
    const [open] = (await s.asEditor("GET", `${s.f}/household`)).data.invites;
    expect(open).toMatchObject({ role: "editor", personId: person.id });
    expect((await s.asEditor("DELETE", `${s.f}/household/invites/${open.id}`)).status).toBe(200);
    expect((await s.asEditor("GET", `${s.f}/household`)).data.invites).toEqual([]);
    expect((await s.asEditor("POST", `${s.f}/household/invites`, { role: "boss" })).status).toBe(400);
  });
});

describe("home address", () => {
  it("sets and clears the home address", async () => {
    const s = setup();
    const set = await s.asEditor("PUT", `${s.f}/household/home`, { address: "Hauptstr. 1, Berlin", lat: 52.5, lng: 13.4 });
    expect(set.data).toEqual({ address: "Hauptstr. 1, Berlin", lat: 52.5, lng: 13.4 });
    const cleared = await s.asEditor("PUT", `${s.f}/household/home`, { address: "", lat: null, lng: null });
    expect(cleared.data).toEqual({ address: null, lat: null, lng: null });
  });
});

describe("notifications", () => {
  it("creates, edits and deletes channels without handing back their secret", async () => {
    const s = setup();
    const created = await s.asEditor("POST", `${s.f}/household/notifications/channels`, {
      name: "Phone",
      provider: "PUSHBULLET",
      token: "secret",
    });
    expect(created.status).toBe(201);
    expect(created.data).toMatchObject({ name: "Phone", provider: "PUSHBULLET", hasToken: true, enabled: true });
    expect(JSON.stringify(created.data)).not.toContain("secret");
    const id = created.data.id;
    const stored = s.db.select().from(notificationChannels).where(eq(notificationChannels.id, id)).get()!.token;

    // A blank token keeps the stored one.
    const edited = await s.asEditor("PATCH", `${s.f}/household/notifications/channels/${id}`, {
      name: "Phone 2",
      provider: "PUSHBULLET",
      token: "",
      enabled: false,
    });
    expect(edited.data).toMatchObject({ name: "Phone 2", enabled: false, hasToken: true });
    expect(s.db.select().from(notificationChannels).where(eq(notificationChannels.id, id)).get()!.token).toBe(stored);

    expect(
      (await s.asEditor("POST", `${s.f}/household/notifications/channels`, { name: "TG", provider: "TELEGRAM", token: "t" })).status,
    ).toBe(400);
    expect((await s.asViewer("GET", `${s.f}/household`)).data.channels).toHaveLength(1);
    expect((await s.asViewer("POST", `${s.f}/household/notifications/channels/${id}/test`)).status).toBe(403);
    expect((await s.asEditor("POST", `${s.f}/household/notifications/channels/nope/test`)).status).toBe(404);
    expect((await s.asEditor("DELETE", `${s.f}/household/notifications/channels/${id}`)).status).toBe(200);
    expect((await s.asEditor("GET", `${s.f}/household`)).data.channels).toEqual([]);
  });

  it("turns events on and off and picks their channels", async () => {
    const s = setup();
    const ch = (await s.asEditor("POST", `${s.f}/household/notifications/channels`, { name: "P", provider: "PUSHBULLET", token: "x" })).data;
    const res = await s.asEditor("PUT", `${s.f}/household/notifications/events/assistant_turn_finished`, {
      enabled: true,
      channelIds: [ch.id],
    });
    expect(res.data).toEqual({ event: "assistant_turn_finished", enabled: true, channelIds: [ch.id], app: true, hasChannels: true });
    // The shopping reminder is gone (the shopping list lives in Reminders).
    expect((await s.asEditor("PUT", `${s.f}/household/notifications/events/shopping_reminder`, { enabled: true, channelIds: null })).status).toBe(404);
    expect((await s.asEditor("PUT", `${s.f}/household/notifications/events/nonsense`, { enabled: true, channelIds: null })).status).toBe(404);
    expect(
      (await s.asEditor("PUT", `${s.f}/household/notifications/events/coverage_gap`, { enabled: true, channelIds: ["other"] })).status,
    ).toBe(404);
    expect((await s.asViewer("PUT", `${s.f}/household/notifications/events/coverage_gap`, { enabled: false, channelIds: null })).status).toBe(403);
    const events = (await s.asEditor("GET", `${s.f}/household`)).data.events;
    expect(events.find((e: any) => e.event === "assistant_turn_finished")).toMatchObject({ enabled: true, channelIds: [ch.id] });
  });
});

describe("the family itself", () => {
  it("is renamed by PATCH on the family (handleFamily) and deleted only by its sole member", async () => {
    const s = setup();
    const renamed = await s.asEditor("PATCH", s.f, { name: "Krüger" });
    expect(renamed.status).toBe(200);
    expect(renamed.data.family.name).toBe("Krüger");
    expect((await s.asViewer("DELETE", `${s.f}/household`)).status).toBe(403);
    expect((await s.asEditor("DELETE", `${s.f}/household`)).status).toBe(400);
    await s.asEditor("DELETE", `${s.f}/household/members/${s.viewer.id}`);
    expect((await s.asEditor("DELETE", `${s.f}/household`)).status).toBe(200);
    expect(s.db.select().from(families).where(eq(families.id, s.family.id)).get()).toBeUndefined();
  });

  it("leaves the family's own routes to handleFamily", async () => {
    const s = setup();
    expect((await s.asEditor("GET", `${s.f}/export`)).data.format).toBe("family-planner");
    expect((await s.asEditor("GET", s.f)).data.family.id).toBe(s.family.id);
  });

  it("creates a family for the token's user, named in their language", () => {
    const s = setup();
    s.db.update(users).set({ preferredLanguage: "de" }).where(eq(users.id, s.outsider.id)).run();
    const user = s.db.select().from(users).where(eq(users.id, s.outsider.id)).get()!;
    const dto = createFamilyForUser(s.db, user, { name: "  Neu  " }, "en-US", NOW);
    expect(dto).toMatchObject({ name: "Neu", role: "editor", memberCount: 1 });
    expect(s.db.select().from(familyMembers).where(eq(familyMembers.familyId, dto.id)).all()).toMatchObject([
      { userId: user.id, role: "editor" },
    ]);
    const names = (lang: string) => {
      const u = makeUser(s.db);
      s.db.update(users).set({ preferredLanguage: lang }).where(eq(users.id, u.id)).run();
      const id = createFamilyForUser(s.db, { id: u.id, preferredLanguage: lang }, { name: "X" }, null, NOW).id;
      return s.db.select().from(calEntryTypes).where(eq(calEntryTypes.familyId, id)).all().map((t) => t.name).sort();
    };
    expect(names("de")).not.toEqual(names("en"));
    expect(() => createFamilyForUser(s.db, user, { name: " " }, null, NOW)).toThrow();
  });
});
