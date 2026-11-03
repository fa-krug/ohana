// The members' photos (lib/families/photos.ts): uploads through the household routes, who may
// set whose, replacing and removing, serving them to the family only, and what happens to them
// when an invite is accepted, someone is removed or the family is deleted.

import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { familyMembers, familyPeople } from "@/lib/db/schema";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { deleteUser } from "@/lib/admin/users";
import { handleFamily } from "@/lib/calendar/family-routes";
import { handleCalendar } from "@/lib/calendar/vacation";
import { handleFamilyApp } from "@/lib/families/app-routes";
import { acceptInvite } from "@/lib/families/invites";
import { deleteFamily } from "@/lib/families/manage";
import { addPerson, familyNames } from "@/lib/families/people";
import { serveImage } from "@/lib/meals/images/serve";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const BASE = "http://ohana.test/api/v1";

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "ohana-photos-"));
  process.env.MEDIA_ROOT = dir;
});
afterEach(() => {
  delete process.env.MEDIA_ROOT;
  rmSync(dir, { recursive: true, force: true });
});

const png = (width = 800, height = 600) =>
  sharp({ create: { width, height, channels: 3, background: "orange" } })
    .png()
    .toBuffer();

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
    async (method: string, path: string, body?: Buffer | FormData, type?: string): Promise<Res> => {
      const token = createToken(db, { userId, kind: "api" }, NOW).token;
      const res = await handler(
        new Request(BASE + path, {
          method,
          headers: { authorization: `Bearer ${token}`, ...(type ? { "content-type": type } : {}) },
          body: Buffer.isBuffer(body) ? new Uint8Array(body) : (body as FormData | undefined),
        }),
      );
      const text = await res.text();
      return { status: res.status, data: text ? JSON.parse(text) : null };
    };
  const editor = makeUser(db, { email: "anna@test", name: "Anna" });
  const viewer = makeUser(db, { email: "ben@test", name: "Ben" });
  const outsider = makeUser(db, { email: "eve@test" });
  const family = makeFamily(db, editor.id, [{ userId: viewer.id, role: "viewer" }]);
  makeFamily(db, outsider.id);
  const f = `/families/${family.id}`;
  return { db, family, f, editor, viewer, outsider, asEditor: as(editor.id), asViewer: as(viewer.id) };
}

const exists = (rel: string) => existsSync(join(dir, rel));

describe("a member's photo", () => {
  it("is set by the member themselves, even a viewer, as a 512×512 WebP", async () => {
    const s = setup();
    const res = await s.asViewer("PUT", `${s.f}/household/members/${s.viewer.id}/photo`, await png(), "image/png");
    expect(res.status).toBe(200);
    expect(res.data).toMatchObject({ userId: s.viewer.id, name: "Ben", role: "viewer" });
    expect(res.data.photo).toBe(`members/${s.family.id}/${s.viewer.id}_${NOW.getTime()}.webp`);
    const meta = await sharp(join(dir, res.data.photo)).metadata();
    expect(meta).toMatchObject({ format: "webp", width: 512, height: 512 });

    const household = (await s.asEditor("GET", `${s.f}/household`)).data;
    expect(household.members.find((m: any) => m.userId === s.viewer.id).photo).toBe(res.data.photo);
    expect(household.members.find((m: any) => m.userId === s.editor.id).photo).toBeNull();
    const calendar = (await s.asEditor("GET", `${s.f}?from=2026-11-01&to=2026-11-30`)).data;
    expect(calendar.members.find((m: any) => m.id === s.viewer.id).photo).toBe(res.data.photo);
    expect(familyNames(s.db, s.family.id).find((m) => m.id === s.viewer.id)?.photo).toBe(res.data.photo);
  });

  it("of someone else needs an editor", async () => {
    const s = setup();
    const res = await s.asViewer("PUT", `${s.f}/household/members/${s.editor.id}/photo`, await png(), "image/png");
    expect(res.status).toBe(403);
    expect((await s.asViewer("DELETE", `${s.f}/household/members/${s.editor.id}/photo`)).status).toBe(403);
    const byEditor = await s.asEditor("PUT", `${s.f}/household/members/${s.viewer.id}/photo`, await png(), "image/png");
    expect(byEditor.status).toBe(200);
    expect(byEditor.data.photo).toMatch(/^members\//);
    expect((await s.asEditor("PUT", `${s.f}/household/members/nobody/photo`, await png(), "image/png")).status).toBe(404);
  });

  it("is taken from a form's image file too", async () => {
    const s = setup();
    const form = new FormData();
    form.set("image", new File([new Uint8Array(await png())], "me.png", { type: "image/png" }));
    const res = await s.asEditor("PUT", `${s.f}/household/members/${s.editor.id}/photo`, form);
    expect(res.status).toBe(200);
    expect(exists(res.data.photo)).toBe(true);
  });

  it("replaces the one before (whose file is deleted) and is removed with DELETE", async () => {
    const s = setup();
    const url = `${s.f}/household/members/${s.editor.id}/photo`;
    const first = (await s.asEditor("PUT", url, await png(), "image/png")).data.photo;
    const second = (await s.asEditor("PUT", url, await png(300, 900), "image/png")).data.photo;
    expect(second).not.toBe(first);
    expect(exists(first)).toBe(false);
    expect(exists(second)).toBe(true);

    const removed = await s.asEditor("DELETE", url);
    expect(removed.status).toBe(200);
    expect(removed.data).toMatchObject({ userId: s.editor.id, photo: null });
    expect(exists(second)).toBe(false);
  });

  it("refuses other types and bytes that aren't an image", async () => {
    const s = setup();
    const url = `${s.f}/household/members/${s.editor.id}/photo`;
    const gif = await s.asEditor("PUT", url, Buffer.from("GIF89a"), "image/gif");
    expect(gif).toEqual({ status: 400, data: { error: "Invalid file type" } });
    const junk = await s.asEditor("PUT", url, Buffer.from("not a picture"), "image/jpeg");
    expect(junk).toEqual({ status: 400, data: { error: "Invalid image" } });
    expect((await s.asEditor("PUT", url, Buffer.alloc(0), "image/png")).status).toBe(400);
  });

  it("is deleted when the member is removed, or their account deleted", async () => {
    const s = setup();
    const own = (await s.asViewer("PUT", `${s.f}/household/members/${s.viewer.id}/photo`, await png(), "image/png")).data.photo;
    expect((await s.asEditor("DELETE", `${s.f}/household/members/${s.viewer.id}`)).status).toBe(200);
    expect(exists(own)).toBe(false);

    const other = makeUser(s.db);
    s.db.insert(familyMembers).values({ familyId: s.family.id, userId: other.id, role: "viewer", joinedAt: NOW }).run();
    const photo = (await s.asEditor("PUT", `${s.f}/household/members/${other.id}/photo`, await png(), "image/png")).data.photo;
    deleteUser(s.db, s.editor.id, other.id);
    expect(exists(photo)).toBe(false);
  });
});

describe("a person's photo", () => {
  it("is set and removed by editors only", async () => {
    const s = setup();
    const { person } = addPerson(s.db, { id: s.editor.id }, s.family.id, { name: "Mia" }, NOW);
    const url = `${s.f}/household/people/${person.id}/photo`;
    expect((await s.asViewer("PUT", url, await png(), "image/png")).status).toBe(403);
    const res = await s.asEditor("PUT", url, await png(), "image/png");
    expect(res.status).toBe(200);
    expect(res.data).toEqual({ id: person.id, name: "Mia", birthday: null, color: person.color, photo: res.data.photo });
    expect(res.data.photo).toBe(`members/${s.family.id}/${person.id}_${NOW.getTime()}.webp`);
    const household = (await s.asViewer("GET", `${s.f}/household`)).data;
    expect(household.people[0].photo).toBe(res.data.photo);
    expect(familyNames(s.db, s.family.id).find((m) => m.id === person.id)?.photo).toBe(res.data.photo);

    expect((await s.asViewer("DELETE", url)).status).toBe(403);
    const removed = await s.asEditor("DELETE", url);
    expect(removed.data).toMatchObject({ id: person.id, photo: null });
    expect(exists(res.data.photo)).toBe(false);
    expect((await s.asEditor("PUT", `${s.f}/household/people/nobody/photo`, await png(), "image/png")).status).toBe(404);
  });

  it("is deleted with the person", async () => {
    const s = setup();
    const { person } = addPerson(s.db, { id: s.editor.id }, s.family.id, { name: "Mia" }, NOW);
    const photo = (await s.asEditor("PUT", `${s.f}/household/people/${person.id}/photo`, await png(), "image/png")).data.photo;
    expect((await s.asEditor("DELETE", `${s.f}/household/people/${person.id}`)).status).toBe(200);
    expect(exists(photo)).toBe(false);
  });

  it("goes to the account that accepts the person's invite", async () => {
    const s = setup();
    const { person, invite } = addPerson(s.db, { id: s.editor.id }, s.family.id, { name: "Leo", invite: "viewer" }, NOW);
    const photo = (await s.asEditor("PUT", `${s.f}/household/people/${person.id}/photo`, await png(), "image/png")).data.photo;
    const leo = makeUser(s.db, { name: "" });
    acceptInvite(s.db, leo.id, invite!.code, NOW);
    const row = s.db.select().from(familyMembers).where(eq(familyMembers.userId, leo.id)).get();
    expect(row?.photo).toBe(photo);
    expect(s.db.select().from(familyPeople).all()).toEqual([]);
    expect(exists(photo)).toBe(true);
    expect((await serveImage(s.db, leo.id, photo)).status).toBe(200);
  });
});

describe("serving photos", () => {
  it("serves them to the family's members only", async () => {
    const s = setup();
    const { person } = addPerson(s.db, { id: s.editor.id }, s.family.id, { name: "Mia" }, NOW);
    const own = (await s.asEditor("PUT", `${s.f}/household/members/${s.editor.id}/photo`, await png(), "image/png")).data.photo;
    const mia = (await s.asEditor("PUT", `${s.f}/household/people/${person.id}/photo`, await png(), "image/png")).data.photo;
    for (const rel of [own, mia]) {
      const res = await serveImage(s.db, s.viewer.id, rel);
      expect(res.status).toBe(200);
      expect(res.headers.get("Content-Type")).toBe("image/webp");
      expect(res.headers.get("Cache-Control")).toBe("private, max-age=31536000, immutable");
      expect((await serveImage(s.db, s.outsider.id, rel)).status).toBe(404);
      expect((await serveImage(s.db, null, rel)).status).toBe(401);
    }
    expect((await serveImage(s.db, s.editor.id, `members/${s.family.id}/nope.webp`)).status).toBe(404);
  });
});

describe("deleting the family", () => {
  it("deletes its photos", async () => {
    const s = setup();
    const { person } = addPerson(s.db, { id: s.editor.id }, s.family.id, { name: "Mia" }, NOW);
    await s.asEditor("PUT", `${s.f}/household/people/${person.id}/photo`, await png(), "image/png");
    await s.asEditor("PUT", `${s.f}/household/members/${s.editor.id}/photo`, await png(), "image/png");
    expect(exists(`members/${s.family.id}`)).toBe(true);
    deleteFamily(s.db, { id: s.editor.id, admin: true }, s.family.id);
    expect(exists(`members/${s.family.id}`)).toBe(false);
  });
});
