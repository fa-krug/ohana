import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import { createTestDb } from "@/lib/test/db";
import { makeFamily, makeUser, NOW } from "@/lib/test/factories";
import { recipes } from "@/lib/db/schema";
import { writeRecipeImage } from "@/lib/meals/images/storage";
import { serveRecipeImage } from "@/lib/meals/images/serve";

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "ohana-images-"));
  process.env.MEDIA_ROOT = dir;
});
afterEach(() => {
  delete process.env.MEDIA_ROOT;
  rmSync(dir, { recursive: true, force: true });
});

async function makeWebp(): Promise<Buffer> {
  return sharp({ create: { width: 1024, height: 768, channels: 3, background: "blue" } })
    .webp({ quality: 85 })
    .toBuffer();
}

async function setup() {
  const db = createTestDb();
  const member = makeUser(db);
  const viewer = makeUser(db);
  const stranger = makeUser(db);
  const family = makeFamily(db, member.id, [{ userId: viewer.id, role: "viewer" }]);
  makeFamily(db, stranger.id);
  const webp = await makeWebp();
  const rel = writeRecipeImage("r1", webp, new Date(1000));
  db.insert(recipes)
    .values({ id: "r1", familyId: family.id, title: "Soup", listType: "KNOWN", image: rel, createdAt: NOW, updatedAt: NOW })
    .run();
  return { db, member, viewer, stranger, rel, webp };
}

describe("serveRecipeImage (GET /api/images/[...path])", () => {
  it("serves the stored image with immutable private caching to a family member", async () => {
    const { db, member, rel, webp } = await setup();
    const res = await serveRecipeImage(db, member.id, rel);
    expect(res.status).toBe(200);
    expect(Buffer.from(await res.arrayBuffer()).length).toBe(webp.length);
    expect(res.headers.get("Content-Type")).toBe("image/webp");
    expect(res.headers.get("Cache-Control")).toBe("private, max-age=31536000, immutable");
  });

  it("serves viewers too", async () => {
    const { db, viewer, rel } = await setup();
    expect((await serveRecipeImage(db, viewer.id, rel)).status).toBe(200);
  });

  it("answers 404 to a member of another family", async () => {
    const { db, stranger, rel } = await setup();
    expect((await serveRecipeImage(db, stranger.id, rel)).status).toBe(404);
  });

  it("answers 401 without a user", async () => {
    const { db, rel } = await setup();
    expect((await serveRecipeImage(db, null, rel)).status).toBe(401);
  });

  it("answers 404 for an image no recipe refers to", async () => {
    const { db, member } = await setup();
    expect((await serveRecipeImage(db, member.id, "recipes/nope.webp")).status).toBe(404);
  });

  it("answers 404 when the file is gone", async () => {
    const { db, member, rel } = await setup();
    rmSync(join(dir, rel));
    expect((await serveRecipeImage(db, member.id, rel)).status).toBe(404);
    expect(db.select().from(recipes).where(eq(recipes.id, "r1")).get()?.image).toBe(rel);
  });
});
