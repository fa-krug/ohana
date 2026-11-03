// The members' photos (lib/families/photos.ts): uploads through the household routes, who may
// set whose, replacing and removing, the kept original and choosing / changing the crop, serving
// them to the family only, and what happens to them when an invite is accepted, someone is
// removed or the family is deleted.

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

/** 800×400: the left half red, the right half blue. */
const halves = (format: "png" | "jpeg" = "png") =>
  sharp({ create: { width: 800, height: 400, channels: 3, background: "red" } })
    .composite([
      {
        input: { create: { width: 400, height: 400, channels: 3, background: "blue" } },
        left: 400,
        top: 0,
      },
    ])
    [format]()
    .toBuffer();

/** The mean red and blue of an image under MEDIA_ROOT. */
async function colorOf(rel: string): Promise<{ red: number; blue: number }> {
  const { channels } = await sharp(join(dir, rel)).stats();
  return { red: channels[0].mean, blue: channels[2].mean };
}

const isRed = (c: { red: number; blue: number }) => c.red > 200 && c.blue < 50;
const isBlue = (c: { red: number; blue: number }) => c.blue > 200 && c.red < 50;

const jsonBody = (body: unknown) => Buffer.from(JSON.stringify(body));

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
  return { db, family, f, editor, viewer, outsider, as, asEditor: as(editor.id), asViewer: as(viewer.id) };
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
    expect(res.data).toEqual({
      id: person.id,
      name: "Mia",
      birthday: null,
      color: person.color,
      photo: res.data.photo,
      photoOriginal: `members/${s.family.id}/${person.id}_${NOW.getTime()}_original.webp`,
      photoCrop: null,
    });
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

describe("the original and the crop", () => {
  it("cuts the square where the query's crop says and keeps the upright original", async () => {
    const s = setup();
    const url = `${s.f}/household/members/${s.editor.id}/photo`;
    const right = await s.asEditor("PUT", `${url}?x=0.5&y=0&w=0.5&h=1`, await halves(), "image/png");
    expect(right.status).toBe(200);
    expect(right.data).toMatchObject({
      photo: `members/${s.family.id}/${s.editor.id}_${NOW.getTime()}.webp`,
      photoOriginal: `members/${s.family.id}/${s.editor.id}_${NOW.getTime()}_original.webp`,
      photoCrop: { x: 0.5, y: 0, w: 0.5, h: 1 },
    });
    expect(await sharp(join(dir, right.data.photo)).metadata()).toMatchObject({ format: "webp", width: 512, height: 512 });
    expect(isBlue(await colorOf(right.data.photo))).toBe(true);
    expect(await sharp(join(dir, right.data.photoOriginal)).metadata()).toMatchObject({
      format: "webp",
      width: 800,
      height: 400,
    });

    const left = await s.asEditor("PUT", `${url}?x=0&y=0&w=0.5&h=1`, await halves(), "image/png");
    expect(isRed(await colorOf(left.data.photo))).toBe(true);
    // The upload before is gone, square and original.
    expect(exists(right.data.photo)).toBe(false);
    expect(exists(right.data.photoOriginal)).toBe(false);
    const household = (await s.asViewer("GET", `${s.f}/household`)).data;
    expect(household.members.find((m: any) => m.userId === s.editor.id)).toMatchObject({
      photo: left.data.photo,
      photoOriginal: left.data.photoOriginal,
      photoCrop: { x: 0, y: 0, w: 0.5, h: 1 },
    });
    // Elsewhere only the square.
    const calendar = (await s.asEditor("GET", `${s.f}?from=2026-11-01&to=2026-11-30`)).data;
    expect(Object.keys(calendar.members.find((m: any) => m.id === s.editor.id))).not.toContain("photoOriginal");
  });

  it("without a crop keeps the original (at most 2048², upright) and has no crop", async () => {
    const s = setup();
    const url = `${s.f}/household/members/${s.editor.id}/photo`;
    const big = await s.asEditor("PUT", url, await png(3000, 1000), "image/png");
    expect(big.status).toBe(200);
    expect(big.data.photoCrop).toBeNull();
    expect(await sharp(join(dir, big.data.photoOriginal)).metadata()).toMatchObject({ width: 2048, height: 683 });

    // A JPEG turned by its EXIF orientation (6: 90° clockwise) is stored upright.
    const turned = await sharp(await halves("jpeg")).withMetadata({ orientation: 6 }).jpeg().toBuffer();
    const res = await s.asEditor("PUT", `${url}?x=0&y=0&w=1&h=0.5`, turned, "image/jpeg");
    expect(res.status).toBe(200);
    expect(await sharp(join(dir, res.data.photoOriginal)).metadata()).toMatchObject({ width: 400, height: 800 });
    // Turned clockwise, the left (red) half is on top.
    expect(isRed(await colorOf(res.data.photo))).toBe(true);
  });

  it("is chosen anew with PATCH, from the original", async () => {
    const s = setup();
    const url = `${s.f}/household/members/${s.viewer.id}/photo`;
    const first = (await s.asViewer("PUT", url, await halves(), "image/png")).data;
    const res = await s.asViewer("PATCH", url, jsonBody({ crop: { x: 0.5, y: 0, w: 0.5, h: 1 } }), "application/json");
    expect(res.status).toBe(200);
    expect(res.data).toMatchObject({ userId: s.viewer.id, photoOriginal: first.photoOriginal, photoCrop: { x: 0.5, y: 0, w: 0.5, h: 1 } });
    expect(res.data.photo).not.toBe(first.photo);
    expect(res.data.photo).toMatch(new RegExp(`^members/${s.family.id}/${s.viewer.id}_\\d+\\.webp$`));
    expect(exists(first.photo)).toBe(false);
    expect(exists(first.photoOriginal)).toBe(true);
    expect(isBlue(await colorOf(res.data.photo))).toBe(true);

    const again = await s.asEditor("PATCH", url, jsonBody({ crop: { x: 0, y: 0, w: 0.5, h: 1 } }), "application/json");
    expect(again.status).toBe(200);
    expect(isRed(await colorOf(again.data.photo))).toBe(true);
    expect(exists(res.data.photo)).toBe(false);
    const household = (await s.asViewer("GET", `${s.f}/household`)).data;
    expect(household.members.find((m: any) => m.userId === s.viewer.id).photoCrop).toEqual({ x: 0, y: 0, w: 0.5, h: 1 });

    // Someone else's needs an editor, as with PUT.
    await s.asEditor("PUT", `${s.f}/household/members/${s.editor.id}/photo`, await halves(), "image/png");
    const other = await s.asViewer(
      "PATCH",
      `${s.f}/household/members/${s.editor.id}/photo`,
      jsonBody({ crop: { x: 0, y: 0, w: 0.5, h: 1 } }),
      "application/json",
    );
    expect(other.status).toBe(403);
  });

  it("of a person is chosen by editors", async () => {
    const s = setup();
    const { person } = addPerson(s.db, { id: s.editor.id }, s.family.id, { name: "Mia" }, NOW);
    const url = `${s.f}/household/people/${person.id}/photo`;
    const put = await s.asEditor("PUT", `${url}?x=0&y=0&w=0.5&h=1`, await halves(), "image/png");
    expect(put.data.photoCrop).toEqual({ x: 0, y: 0, w: 0.5, h: 1 });
    expect(isRed(await colorOf(put.data.photo))).toBe(true);
    const body = jsonBody({ crop: { x: 0.5, y: 0, w: 0.5, h: 1 } });
    expect((await s.asViewer("PATCH", url, body, "application/json")).status).toBe(403);
    const res = await s.asEditor("PATCH", url, body, "application/json");
    expect(res.status).toBe(200);
    expect(res.data).toMatchObject({ id: person.id, photoOriginal: put.data.photoOriginal, photoCrop: { x: 0.5, y: 0, w: 0.5, h: 1 } });
    expect(isBlue(await colorOf(res.data.photo))).toBe(true);
    expect(exists(put.data.photo)).toBe(false);
  });

  it("refuses crops outside the picture and a partial query", async () => {
    const s = setup();
    const url = `${s.f}/household/members/${s.editor.id}/photo`;
    const put = (await s.asEditor("PUT", url, await halves(), "image/png")).data;
    const bad = [
      { x: 0.6, y: 0, w: 0.5, h: 1 },
      { x: -0.1, y: 0, w: 0.5, h: 1 },
      { x: 0, y: 0, w: 0, h: 1 },
      { x: 0, y: 0, w: 0.5, h: -1 },
      { x: 0, y: 0, w: 0.5 },
      { x: "0", y: 0, w: 0.5, h: 1 },
      null,
    ];
    for (const crop of bad) {
      const res = await s.asEditor("PATCH", url, jsonBody({ crop }), "application/json");
      expect(res).toEqual({ status: 400, data: { error: "Invalid crop." } });
    }
    expect((await s.asEditor("PATCH", url, jsonBody({}), "application/json")).status).toBe(400);
    for (const query of ["?x=0&y=0&w=0.5", "?x=abc&y=0&w=0.5&h=1", "?x=&y=0&w=0.5&h=1", "?x=0.9&y=0&w=0.5&h=1", "?x=Infinity&y=0&w=0.5&h=1"]) {
      const res = await s.asEditor("PUT", url + query, await halves(), "image/png");
      expect(res.status).toBe(400);
    }
    // Nothing changed.
    const household = (await s.asEditor("GET", `${s.f}/household`)).data;
    expect(household.members.find((m: any) => m.userId === s.editor.id)).toMatchObject({ photo: put.photo, photoCrop: null });

    // Rounding slack is clamped into the picture.
    const slack = await s.asEditor("PATCH", url, jsonBody({ crop: { x: 0.5, y: -1e-7, w: 0.5000001, h: 1 } }), "application/json");
    expect(slack.status).toBe(200);
    expect(slack.data.photoCrop.y).toBe(0);
    expect(slack.data.photoCrop.x + slack.data.photoCrop.w).toBeLessThanOrEqual(1);
  });

  it("can't be changed without an original (409) or a photo (404)", async () => {
    const s = setup();
    const url = `${s.f}/household/members/${s.editor.id}/photo`;
    const body = jsonBody({ crop: { x: 0, y: 0, w: 0.5, h: 1 } });
    expect(await s.asEditor("PATCH", url, body, "application/json")).toEqual({ status: 404, data: { error: "No photo." } });
    // A photo from before originals were kept.
    s.db
      .update(familyMembers)
      .set({ photo: `members/${s.family.id}/${s.editor.id}_1.webp` })
      .where(eq(familyMembers.userId, s.editor.id))
      .run();
    expect(await s.asEditor("PATCH", url, body, "application/json")).toEqual({
      status: 409,
      data: { error: "This photo can't be adjusted." },
    });
    expect((await s.asEditor("PATCH", `${s.f}/household/members/nobody/photo`, body, "application/json")).status).toBe(404);
  });

  it("goes with the photo: DELETE removes both files and clears all three", async () => {
    const s = setup();
    const url = `${s.f}/household/members/${s.editor.id}/photo`;
    const put = (await s.asEditor("PUT", `${url}?x=0&y=0&w=0.5&h=1`, await halves(), "image/png")).data;
    const removed = await s.asEditor("DELETE", url);
    expect(removed.data).toMatchObject({ photo: null, photoOriginal: null, photoCrop: null });
    expect(exists(put.photo)).toBe(false);
    expect(exists(put.photoOriginal)).toBe(false);
    const row = s.db.select().from(familyMembers).where(eq(familyMembers.userId, s.editor.id)).get();
    expect(row).toMatchObject({ photo: null, photoOriginal: null, photoCrop: null });
  });

  it("serves the original to the family's members only", async () => {
    const s = setup();
    const { person } = addPerson(s.db, { id: s.editor.id }, s.family.id, { name: "Mia" }, NOW);
    const own = (await s.asEditor("PUT", `${s.f}/household/members/${s.editor.id}/photo`, await png(), "image/png")).data;
    const mia = (await s.asEditor("PUT", `${s.f}/household/people/${person.id}/photo`, await png(), "image/png")).data;
    for (const rel of [own.photoOriginal, mia.photoOriginal]) {
      const res = await serveImage(s.db, s.viewer.id, rel);
      expect(res.status).toBe(200);
      expect(res.headers.get("Content-Type")).toBe("image/webp");
      expect(res.headers.get("Cache-Control")).toBe("private, max-age=31536000, immutable");
      expect((await serveImage(s.db, s.outsider.id, rel)).status).toBe(404);
    }
  });

  it("goes to the account that accepts the person's invite", async () => {
    const s = setup();
    const { person, invite } = addPerson(s.db, { id: s.editor.id }, s.family.id, { name: "Leo", invite: "viewer" }, NOW);
    const put = (await s.asEditor("PUT", `${s.f}/household/people/${person.id}/photo?x=0.5&y=0&w=0.5&h=1`, await halves(), "image/png")).data;
    const leo = makeUser(s.db, { name: "" });
    acceptInvite(s.db, leo.id, invite!.code, NOW);
    const row = s.db.select().from(familyMembers).where(eq(familyMembers.userId, leo.id)).get();
    expect(row).toMatchObject({ photo: put.photo, photoOriginal: put.photoOriginal });
    expect(JSON.parse(row!.photoCrop!)).toEqual({ x: 0.5, y: 0, w: 0.5, h: 1 });
    expect(exists(put.photoOriginal)).toBe(true);
    expect((await serveImage(s.db, leo.id, put.photoOriginal)).status).toBe(200);
    const household = (await s.asEditor("GET", `${s.f}/household`)).data;
    expect(household.members.find((m: any) => m.userId === leo.id).photoCrop).toEqual({ x: 0.5, y: 0, w: 0.5, h: 1 });
    // Leo crops it anew himself.
    const res = await s.as(leo.id)(
      "PATCH",
      `${s.f}/household/members/${leo.id}/photo`,
      jsonBody({ crop: { x: 0, y: 0, w: 0.5, h: 1 } }),
      "application/json",
    );
    expect(res.status).toBe(200);
    expect(isRed(await colorOf(res.data.photo))).toBe(true);
  });

  it("is deleted with the person, the member and the account", async () => {
    const s = setup();
    const { person } = addPerson(s.db, { id: s.editor.id }, s.family.id, { name: "Mia" }, NOW);
    const mia = (await s.asEditor("PUT", `${s.f}/household/people/${person.id}/photo`, await png(), "image/png")).data;
    expect((await s.asEditor("DELETE", `${s.f}/household/people/${person.id}`)).status).toBe(200);
    expect(exists(mia.photo)).toBe(false);
    expect(exists(mia.photoOriginal)).toBe(false);

    const ben = (await s.asViewer("PUT", `${s.f}/household/members/${s.viewer.id}/photo`, await png(), "image/png")).data;
    expect((await s.asEditor("DELETE", `${s.f}/household/members/${s.viewer.id}`)).status).toBe(200);
    expect(exists(ben.photo)).toBe(false);
    expect(exists(ben.photoOriginal)).toBe(false);

    const other = makeUser(s.db);
    s.db.insert(familyMembers).values({ familyId: s.family.id, userId: other.id, role: "viewer", joinedAt: NOW }).run();
    const theirs = (await s.asEditor("PUT", `${s.f}/household/members/${other.id}/photo`, await png(), "image/png")).data;
    deleteUser(s.db, s.editor.id, other.id);
    expect(exists(theirs.photo)).toBe(false);
    expect(exists(theirs.photoOriginal)).toBe(false);
  });
});
