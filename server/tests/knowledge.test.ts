// The knowledge base (/families/{id}/knowledge…): editors only (404 for viewers), the folder, the
// manifest's diff (uploads, moves, missing files and their return), uploads, the document list
// and its filters, exclude / reindex, tags, the FTS search (umlauts, prefixes, only ready
// documents, one family's) and the 30-day cleanup of missing documents.

import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq, sql } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { kbChunks, kbDocuments } from "@/lib/db/schema";
import { createFamilyApi } from "@/lib/api/family-api";
import { handleDisabledModules } from "@/lib/api/disabled-modules";
import { createToken } from "@/lib/auth/tokens";
import { acceptInvite } from "@/lib/families/invites";
import { removeMember } from "@/lib/families/members";
import { addPerson } from "@/lib/families/people";
import { MAX_TEXT_BYTES } from "@/lib/knowledge/documents";
import { ensureFolder } from "@/lib/knowledge/folders";
import { normalizePath } from "@/lib/knowledge/input";
import { handleKnowledge } from "@/lib/knowledge/routes";
import { ftsTerms, searchKnowledge } from "@/lib/knowledge/search";
import { cleanup } from "@/lib/maintenance/cleanup";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const BASE = "http://ohana.test/api/v1";
const DAY = 24 * 60 * 60 * 1000;

let db: Db;
let editorId: string;
let viewerId: string;
let familyId: string;
let now: Date;

function call(userId: string, family = familyId) {
  const handler = createFamilyApi([handleDisabledModules, handleKnowledge], { db, appUrl: "http://ohana.test", now: () => now });
  const token = createToken(db, { userId, kind: "api" }, NOW).token;
  return async (method: string, path: string, body?: unknown) => {
    const res = await handler(
      new Request(BASE + `/families/${family}` + path, {
        method,
        headers: {
          authorization: `Bearer ${token}`,
          ...(body !== undefined ? { "content-type": "application/json" } : {}),
        },
        body: body !== undefined ? JSON.stringify(body) : undefined,
      }),
    );
    return { status: res.status, data: await res.json() };
  };
}

const sha = (s: string) => createHash("sha256").update(s).digest("hex");

function file(path: string, content = path, extra: { tags?: string[]; mtime?: number; size?: number } = {}) {
  return { path, size: extra.size ?? content.length, mtime: extra.mtime ?? 1_700_000_000_000, hash: sha(content), tags: extra.tags ?? [] };
}

function docByPath(path: string) {
  return db.select().from(kbDocuments).where(eq(kbDocuments.path, path)).get();
}

/** What the worker will do: chunks, ready. */
function index(documentId: string, chunks: { page: number; text: string }[]) {
  const doc = db.select().from(kbDocuments).where(eq(kbDocuments.id, documentId)).get()!;
  db.delete(kbChunks).where(eq(kbChunks.documentId, documentId)).run();
  chunks.forEach((c, seq) => db.insert(kbChunks).values({ documentId, familyId: doc.familyId, seq, page: c.page, text: c.text }).run());
  db.update(kbDocuments).set({ status: "ready", indexedAt: now }).where(eq(kbDocuments.id, documentId)).run();
}

beforeEach(() => {
  db = createTestDb();
  now = NOW;
  editorId = makeUser(db, { name: "Anna" }).id;
  viewerId = makeUser(db, { name: "Ben" }).id;
  familyId = makeFamily(db, editorId, [{ userId: viewerId, role: "viewer" }]).id;
});

afterEach(() => {
  delete process.env.DISABLED_MODULES;
});

/** The family's folder and an upload helper. */
async function setup() {
  const edit = call(editorId);
  const folderId = (await edit("POST", "/knowledge/folder")).data.folder.id as string;
  const upload = (f: ReturnType<typeof file>, pages: string[] = ["text"]) => edit("PUT", "/knowledge/documents", { folderId, ...f, pages });
  const manifest = (files: ReturnType<typeof file>[]) => edit("POST", "/knowledge/manifest", { folderId, files });
  return { edit, folderId, upload, manifest };
}

describe("knowledge: access", () => {
  it("has one folder per family, created on first use", async () => {
    const edit = call(editorId);
    expect(await edit("GET", "/knowledge/folder")).toEqual({ status: 200, data: { folder: null } });
    const first = await edit("POST", "/knowledge/folder");
    expect(first).toEqual({
      status: 201,
      data: { folder: { id: expect.any(String), createdAt: NOW.toISOString(), lastManifestAt: null, lastManifestDevice: null } },
    });
    const again = await edit("POST", "/knowledge/folder");
    expect(again).toEqual({ status: 200, data: first.data });
    expect((await edit("GET", "/knowledge/folder")).data).toEqual(first.data);
  });

  it("replaces the folder on request: a new id, the old one's documents and FTS rows gone", async () => {
    const { edit, folderId, upload, manifest } = await setup();
    const { data } = await upload(file("a.pdf"));
    index(data.id, [{ page: 1, text: "Kündigung der Hausratversicherung" }]);
    const fts = () => db.all<{ rowid: number }>(sql`SELECT rowid FROM kb_chunks_fts WHERE kb_chunks_fts MATCH 'kundigung'`);
    expect(fts()).toHaveLength(1);
    // Without replace (or with false) it stays the same folder.
    expect(await edit("POST", "/knowledge/folder", { replace: false })).toMatchObject({ status: 200, data: { folder: { id: folderId } } });
    expect((await edit("POST", "/knowledge/folder", { replace: "yes" })).status).toBe(400);

    now = new Date(NOW.getTime() + 60_000);
    const replaced = await edit("POST", "/knowledge/folder", { replace: true });
    expect(replaced).toEqual({
      status: 201,
      data: { folder: { id: expect.any(String), createdAt: now.toISOString(), lastManifestAt: null, lastManifestDevice: null } },
    });
    const newId = replaced.data.folder.id;
    expect(newId).not.toBe(folderId);
    expect((await edit("GET", "/knowledge/folder")).data.folder.id).toBe(newId);
    expect(db.select().from(kbDocuments).all()).toEqual([]);
    expect(db.select().from(kbChunks).all()).toEqual([]);
    expect(fts()).toEqual([]);
    db.run(sql`INSERT INTO kb_chunks_fts(kb_chunks_fts) VALUES ('integrity-check')`);

    // The old id is gone.
    expect((await manifest([file("a.pdf")])).status).toBe(404);
    expect((await upload(file("a.pdf"))).status).toBe(404);
    const fresh = await edit("POST", "/knowledge/manifest", { folderId: newId, files: [file("a.pdf")] });
    expect(fresh).toEqual({ status: 200, data: { upload: ["a.pdf"] } });
    // Without replace it's idempotent again: the new folder.
    expect(await edit("POST", "/knowledge/folder")).toMatchObject({ status: 200, data: { folder: { id: newId } } });
  });

  it("answers viewers 404 on every route, as if it didn't exist", async () => {
    const { folderId, upload } = await setup();
    const { data } = await upload(file("a.pdf"));
    const view = call(viewerId);
    const routes: [string, string, unknown?][] = [
      ["GET", "/knowledge/folder"],
      ["POST", "/knowledge/folder"],
      ["POST", "/knowledge/manifest", { folderId, files: [] }],
      ["PUT", "/knowledge/documents", { folderId, ...file("b.pdf"), pages: [] }],
      ["GET", "/knowledge/documents"],
      ["GET", `/knowledge/documents/${data.id}`],
      ["POST", `/knowledge/documents/${data.id}/reindex`],
      ["POST", `/knowledge/documents/${data.id}/exclude`, { excluded: true }],
      ["GET", "/knowledge/tags"],
      ["GET", "/knowledge/status"],
      ["DELETE", "/knowledge/folder"],
      ["GET", "/knowledge/nothing"],
    ];
    for (const [method, path, body] of routes) {
      expect(await view(method, path, body), `${method} ${path}`).toEqual({ status: 404, data: { error: "Not found" } });
    }
    // Nothing changed.
    expect(docByPath("b.pdf")).toBeUndefined();
    expect(docByPath("a.pdf")!.status).toBe("pending");
  });

  it("answers 404 to non-members and another family's ids", async () => {
    const { folderId, upload } = await setup();
    const { data } = await upload(file("a.pdf"));
    const strangerId = makeUser(db).id;
    expect((await call(strangerId)("GET", "/knowledge/folder")).status).toBe(404);
    const otherFamily = makeFamily(db, strangerId).id;
    const stranger = call(strangerId, otherFamily);
    expect((await stranger("GET", `/knowledge/documents/${data.id}`)).status).toBe(404);
    expect((await stranger("POST", "/knowledge/manifest", { folderId, files: [] })).status).toBe(404);
    expect((await stranger("PUT", "/knowledge/documents", { folderId, ...file("x.pdf"), pages: [] })).status).toBe(404);
  });

  it("is 404 while the module is turned off", async () => {
    process.env.DISABLED_MODULES = "knowledge";
    const res = await call(editorId)("GET", "/knowledge/folder");
    expect(res).toEqual({ status: 404, data: { error: "This module is turned off on this server" } });
  });

  it("answers unknown paths 404 and wrong methods 405 for editors", async () => {
    const edit = call(editorId);
    expect((await edit("GET", "/knowledge/nothing")).status).toBe(404);
    expect((await edit("DELETE", "/knowledge/folder")).status).toBe(405);
    expect((await edit("POST", "/knowledge/status")).status).toBe(405);
    expect((await edit("GET", "/knowledge/status/x")).status).toBe(404);
    expect((await edit("GET", "/knowledge/documents/x/reindex")).status).toBe(405);
  });
});

describe("knowledge: manifest", () => {
  it("asks for new files, not for known ones, and updates tags in place", async () => {
    const { manifest, upload } = await setup();
    const a = file("Verträge/Strom.pdf");
    const b = file("Scan 2026-10-01.pdf");
    expect(await manifest([a, b])).toEqual({ status: 200, data: { upload: [a.path, b.path] } });
    await upload(a);
    await upload(b);
    const before = docByPath(a.path)!;

    now = new Date(NOW.getTime() + 60_000);
    const tagged = { ...a, tags: ["Strom", "Vertrag"], mtime: a.mtime + 5 };
    expect((await manifest([tagged, b])).data).toEqual({ upload: [] });
    const after = docByPath(a.path)!;
    expect(JSON.parse(after.tags)).toEqual(["Strom", "Vertrag"]);
    expect(after.mtime).toBe(a.mtime + 5);
    expect(after.updatedAt.getTime()).toBe(now.getTime());
    expect(after.status).toBe(before.status);
    // Nothing changed: the row isn't touched.
    expect(docByPath(b.path)!.updatedAt.getTime()).toBe(NOW.getTime());
  });

  it("asks again for a file whose content changed, keeping the stored hash until it comes", async () => {
    const { manifest, upload } = await setup();
    const a = file("a.pdf", "v1");
    await upload(a);
    const changed = file("a.pdf", "v2", { tags: ["Neu"] });
    expect((await manifest([changed])).data).toEqual({ upload: ["a.pdf"] });
    const row = docByPath("a.pdf")!;
    expect(row.hash).toBe(a.hash);
    expect(JSON.parse(row.tags)).toEqual(["Neu"]);
  });

  it("moves a renamed file's document instead of asking for it", async () => {
    const { manifest, upload } = await setup();
    const a = file("Inbox/Brief.pdf", "letter");
    await upload(a);
    const id = docByPath(a.path)!.id;
    index(id, [{ page: 1, text: "Sehr geehrte Familie" }]);

    const moved = file("Versicherungen/Auto/Brief Allianz.pdf", "letter", { tags: ["Auto"] });
    expect((await manifest([moved])).data).toEqual({ upload: [] });
    const row = db.select().from(kbDocuments).where(eq(kbDocuments.id, id)).get()!;
    expect(row).toMatchObject({ path: moved.path, name: "Brief Allianz.pdf", status: "ready", missingSince: null });
    expect(JSON.parse(row.tags)).toEqual(["Auto"]);
    expect(docByPath(a.path)).toBeUndefined();
    expect(db.select().from(kbChunks).where(eq(kbChunks.documentId, id)).all()).toHaveLength(1);
  });

  it("asks for a copy (the original is still listed)", async () => {
    const { manifest, upload } = await setup();
    const a = file("a.pdf", "same");
    await upload(a);
    expect((await manifest([a, file("copy of a.pdf", "same")])).data).toEqual({ upload: ["copy of a.pdf"] });
  });

  it("marks files no longer listed missing and brings them back as they were", async () => {
    const { manifest, upload } = await setup();
    const ready = file("ready.pdf");
    const pending = file("pending.pdf");
    const failed = file("failed.pdf");
    for (const f of [ready, pending, failed]) await upload(f);
    index(docByPath("ready.pdf")!.id, [{ page: 1, text: "x" }]);
    db.update(kbDocuments).set({ status: "failed", error: "Unreadable" }).where(eq(kbDocuments.path, "failed.pdf")).run();
    db.update(kbDocuments).set({ runToken: "t", runUntil: new Date(NOW.getTime() + 60_000) }).where(eq(kbDocuments.path, "pending.pdf")).run();

    db.update(kbDocuments).set({ attempts: 2 }).where(eq(kbDocuments.path, "pending.pdf")).run();
    const other = file("other.pdf");
    await upload(other);

    expect((await manifest([other])).data).toEqual({ upload: [] });
    for (const p of ["ready.pdf", "pending.pdf", "failed.pdf"]) {
      expect(docByPath(p)).toMatchObject({ status: "missing", missingSince: NOW });
    }
    // The worker's lease is gone: its run can't save over "missing".
    expect(docByPath("pending.pdf")!.runToken).toBeNull();

    // Still missing a day later: since the first time.
    now = new Date(NOW.getTime() + DAY);
    await manifest([other]);
    expect(docByPath("ready.pdf")!.missingSince).toEqual(NOW);

    expect((await manifest([ready, pending, failed, other])).data).toEqual({ upload: [] });
    expect(docByPath("ready.pdf")).toMatchObject({ status: "ready", missingSince: null });
    // Waiting again: a fresh count of runs.
    expect(docByPath("pending.pdf")).toMatchObject({ status: "pending", missingSince: null, attempts: 0 });
    expect(docByPath("failed.pdf")).toMatchObject({ status: "failed", missingSince: null, error: "Unreadable" });
  });

  it("moves a missing document when its file turns up elsewhere later", async () => {
    const { manifest, upload } = await setup();
    const a = file("a.pdf", "content");
    await upload(a);
    await upload(file("other.pdf"));
    await manifest([file("other.pdf")]);
    expect(docByPath("a.pdf")!.status).toBe("missing");
    expect((await manifest([file("b/a.pdf", "content")])).data).toEqual({ upload: [] });
    expect(docByPath("b/a.pdf")).toMatchObject({ status: "pending", missingSince: null });
  });

  it("never asks for excluded files; an excluded one stays excluded while gone", async () => {
    const { edit, manifest, upload } = await setup();
    const a = file("a.pdf", "v1");
    const { data } = await upload(a);
    await edit("POST", `/knowledge/documents/${data.id}/exclude`, { excluded: true });
    expect((await manifest([file("a.pdf", "v2")])).data).toEqual({ upload: [] });
    await manifest([file("other.pdf")]);
    expect(docByPath("a.pdf")).toMatchObject({ status: "excluded", missingSince: NOW });
    await manifest([a]);
    expect(docByPath("a.pdf")).toMatchObject({ status: "excluded", missingSince: null });
  });

  it("marks nothing missing for an empty manifest (a folder the device can't read)", async () => {
    const { manifest, upload } = await setup();
    const a = file("a.pdf");
    await upload(a);
    index(docByPath("a.pdf")!.id, [{ page: 1, text: "x" }]);
    expect(await manifest([])).toEqual({ status: 200, data: { upload: [] } });
    expect(docByPath("a.pdf")).toMatchObject({ status: "ready", missingSince: null });
  });

  it("checks the paths and the folder", async () => {
    const { manifest, edit } = await setup();
    const bad = ["/abs.pdf", "a/../b.pdf", "a//b.pdf", "a/", "", ".hidden.pdf", "a/.DS_Store", "x\\y.pdf", "a/./b.pdf", "a".repeat(1025)];
    for (const path of bad) {
      expect((await manifest([{ ...file("x"), path }])).status, JSON.stringify(path)).toBe(400);
    }
    expect((await manifest([{ ...file("x"), hash: "abc" }])).status).toBe(400);
    expect((await manifest([{ ...file("x"), size: -1 }])).status).toBe(400);
    expect((await manifest([{ ...file("x"), tags: [1 as unknown as string] }])).status).toBe(400);
    // NFC: the same name decomposed is the same path, listed twice.
    const nfd = "Ku\u0308ndigung.pdf";
    expect((await manifest([file(nfd), file("Kündigung.pdf")])).status).toBe(400);
    expect((await manifest([file(nfd)])).data).toEqual({ upload: ["Kündigung.pdf"] });
    expect((await edit("POST", "/knowledge/manifest", { folderId: "nope", files: [] })).status).toBe(404);
    expect((await edit("POST", "/knowledge/manifest", { folderId: "nope" })).status).toBe(404);
    expect(normalizePath("Ordner/Unterordner/Datei.pdf")).toBe("Ordner/Unterordner/Datei.pdf");
  });

  it("counts a file listed without a hash as present, without asking for or moving it", async () => {
    const { manifest, upload, edit, folderId } = await setup();
    const unhashed = (f: ReturnType<typeof file>, tags: string[] = f.tags) => ({ ...f, hash: null, size: 1, mtime: 2, tags });
    const a = file("a.pdf", "v1");
    const gone = file("gone.pdf", "gone");
    await upload(a);
    await upload(gone);
    index(docByPath("a.pdf")!.id, [{ page: 1, text: "x" }]);
    const sendRaw = (files: unknown[]) => edit("POST", "/knowledge/manifest", { folderId, files });

    // Known path: present (not missing), tags updated, size / time / hash kept, not asked for.
    expect((await sendRaw([unhashed(a, ["Neu"]), gone])).data).toEqual({ upload: [] });
    expect(docByPath("a.pdf")).toMatchObject({ status: "ready", missingSince: null, hash: a.hash, size: a.size, mtime: a.mtime });
    expect(JSON.parse(docByPath("a.pdf")!.tags)).toEqual(["Neu"]);

    // Missing, then listed without a hash: back.
    await manifest([gone]);
    expect(docByPath("a.pdf")!.status).toBe("missing");
    expect((await sendRaw([unhashed(a), gone])).data).toEqual({ upload: [] });
    expect(docByPath("a.pdf")).toMatchObject({ status: "ready", missingSince: null });

    // An unknown path without a hash: ignored, nothing created.
    expect((await sendRaw([unhashed(a), gone, unhashed(file("new.pdf"))])).data).toEqual({ upload: [] });
    expect(docByPath("new.pdf")).toBeUndefined();

    // Not a move target: gone.pdf's document stays, missing, instead of moving to b.pdf.
    expect((await sendRaw([unhashed(a), unhashed(file("b.pdf", "gone"))])).data).toEqual({ upload: [] });
    expect(docByPath("gone.pdf")).toMatchObject({ status: "missing" });
    expect(docByPath("b.pdf")).toBeUndefined();

    // Not a move source: a.pdf listed without a hash stays; its content at another path is a copy.
    const copy = file("copy.pdf", "v1");
    expect((await sendRaw([unhashed(a), copy])).data).toEqual({ upload: ["copy.pdf"] });
    expect(docByPath("a.pdf")).toMatchObject({ status: "ready" });

    // size and mtime are still required.
    expect((await sendRaw([{ ...unhashed(a), size: undefined }])).status).toBe(400);
    expect((await sendRaw([{ ...unhashed(a), mtime: null }])).status).toBe(400);
  });

  it("limits the number of files", async () => {
    const { manifest } = await setup();
    const files = Array.from({ length: 20_001 }, (_, i) => file(`f${i}.pdf`));
    expect((await manifest(files)).status).toBe(413);
  });
});

describe("knowledge: status", () => {
  it("is empty without a folder", async () => {
    expect(await call(editorId)("GET", "/knowledge/status")).toEqual({
      status: 200,
      data: { folder: null, counts: { pending: 0, ready: 0, failed: 0, missing: 0, excluded: 0 }, chunks: 0 },
    });
  });

  it("notes the last non-empty manifest and its device", async () => {
    const { edit, folderId, manifest } = await setup();
    const folder = () => edit("GET", "/knowledge/folder").then((r) => r.data.folder);
    await manifest([file("a.pdf")]);
    expect(await folder()).toMatchObject({ lastManifestAt: NOW.toISOString(), lastManifestDevice: null });

    now = new Date(NOW.getTime() + 61_500);
    const sent = await edit("POST", "/knowledge/manifest", { folderId, device: "  Annas iPhone  ", files: [file("a.pdf")] });
    expect(sent.status).toBe(200);
    expect(await folder()).toMatchObject({ lastManifestAt: now.toISOString(), lastManifestDevice: "Annas iPhone" });

    // An empty manifest (a folder the device can't read) changes nothing.
    const before = now;
    now = new Date(NOW.getTime() + 120_000);
    await edit("POST", "/knowledge/manifest", { folderId, device: "Mac", files: [] });
    expect(await folder()).toMatchObject({ lastManifestAt: before.toISOString(), lastManifestDevice: "Annas iPhone" });

    // A blank name is none; one that isn't text is a 400.
    await edit("POST", "/knowledge/manifest", { folderId, device: "   ", files: [file("a.pdf")] });
    expect(await folder()).toMatchObject({ lastManifestAt: now.toISOString(), lastManifestDevice: null });
    expect((await edit("POST", "/knowledge/manifest", { folderId, device: 7, files: [file("b.pdf")] })).status).toBe(400);
    // A long one is cut to 100 UTF-16 units, never inside a surrogate pair.
    const device = async (name: string) => {
      expect((await edit("POST", "/knowledge/manifest", { folderId, device: name, files: [file("a.pdf")] })).status).toBe(200);
      return (await folder()).lastManifestDevice as string;
    };
    expect(await device("x".repeat(100))).toBe("x".repeat(100));
    expect(await device("x".repeat(150))).toBe("x".repeat(100));
    expect(await device("x".repeat(99) + "😀" + "y")).toBe("x".repeat(99));
    expect(await device("x".repeat(98) + "😀" + "y")).toBe("x".repeat(98) + "😀");
    expect(await device("x".repeat(90) + " ".repeat(20) + "y")).toBe("x".repeat(90));
  });

  it("counts the family's documents by status and its chunks", async () => {
    const { edit, folderId, upload } = await setup();
    for (const name of ["ready.pdf", "ready2.pdf", "failed.pdf", "gone.pdf", "excluded.pdf", "pending.pdf"]) await upload(file(name));
    index(docByPath("ready.pdf")!.id, [{ page: 1, text: "a" }, { page: 1, text: "b" }]);
    index(docByPath("ready2.pdf")!.id, [{ page: 1, text: "c" }]);
    db.update(kbDocuments).set({ status: "failed", error: "Unreadable" }).where(eq(kbDocuments.path, "failed.pdf")).run();
    await edit("POST", `/knowledge/documents/${docByPath("excluded.pdf")!.id}/exclude`, { excluded: true });
    now = new Date(NOW.getTime() + 1000);
    await edit("POST", "/knowledge/manifest", {
      folderId,
      device: "iPad",
      files: ["ready.pdf", "ready2.pdf", "failed.pdf", "excluded.pdf", "pending.pdf"].map((n) => file(n)),
    });
    // Another family's documents don't count.
    const otherEditor = makeUser(db).id;
    const otherFamily = makeFamily(db, otherEditor).id;
    const other = call(otherEditor, otherFamily);
    const otherFolder = (await other("POST", "/knowledge/folder")).data.folder.id;
    await other("PUT", "/knowledge/documents", { folderId: otherFolder, ...file("x.pdf"), pages: ["x"] });

    expect(await edit("GET", "/knowledge/status")).toEqual({
      status: 200,
      data: {
        folder: { id: folderId, createdAt: NOW.toISOString(), lastManifestAt: now.toISOString(), lastManifestDevice: "iPad" },
        counts: { pending: 1, ready: 2, failed: 1, missing: 1, excluded: 1 },
        chunks: 3,
      },
    });
  });
});

describe("knowledge: uploads", () => {
  it("stores the text and is idempotent by path and hash", async () => {
    const { upload } = await setup();
    const a = file("Kündigung.pdf", "v1", { tags: ["Vertrag"] });
    const first = await upload(a, ["Seite 1", "Seite 2"]);
    expect(first).toEqual({ status: 202, data: { id: expect.any(String), status: "pending" } });
    const row = docByPath("Kündigung.pdf")!;
    expect(row).toMatchObject({ name: "Kündigung.pdf", pages: 2, hash: a.hash, status: "pending", familyId });
    expect(JSON.parse(row.text)).toEqual(["Seite 1", "Seite 2"]);

    index(first.data.id, [{ page: 1, text: "Seite 1" }]);
    expect(await upload(a, ["Seite 1", "Seite 2"])).toEqual({ status: 202, data: { id: first.data.id, status: "ready" } });
    expect(db.select().from(kbChunks).all()).toHaveLength(1);

    // New content: waits for the worker, the old chunks and card are gone at once.
    db.update(kbDocuments).set({ summary: "Old", facts: "[]" }).where(eq(kbDocuments.id, first.data.id)).run();
    const v2 = file("Kündigung.pdf", "v2");
    expect(await upload(v2, ["Neu"])).toEqual({ status: 202, data: { id: first.data.id, status: "pending" } });
    expect(docByPath("Kündigung.pdf")).toMatchObject({ hash: v2.hash, pages: 1, summary: null, facts: null, indexedAt: null });
    expect(db.select().from(kbChunks).all()).toHaveLength(0);
  });

  it("takes a failed document's text again", async () => {
    const { upload } = await setup();
    const a = file("a.pdf");
    const { data } = await upload(a, [""]);
    db.update(kbDocuments).set({ status: "failed", error: "No text" }).where(eq(kbDocuments.id, data.id)).run();
    expect((await upload(a, ["Text from OCR"])).data).toEqual({ id: data.id, status: "pending" });
    expect(docByPath("a.pdf")!.error).toBeNull();
  });

  it("takes text for a document stored without any, even with the same hash", async () => {
    const { upload } = await setup();
    const a = file("scan.pdf");
    const { data } = await upload(a, ["", "  \n "]);
    index(data.id, []);
    expect(docByPath("scan.pdf")).toMatchObject({ status: "ready", attempts: 0 });
    // Without text again: nothing changes.
    expect((await upload(a, [""])).data).toEqual({ id: data.id, status: "ready" });
    db.update(kbDocuments).set({ attempts: 1 }).where(eq(kbDocuments.id, data.id)).run();
    // A device that reads it: the text is taken, the worker runs again.
    expect((await upload(a, ["Rechnung 42"])).data).toEqual({ id: data.id, status: "pending" });
    expect(docByPath("scan.pdf")).toMatchObject({ pages: 1, indexedAt: null, attempts: 0 });
    expect(JSON.parse(docByPath("scan.pdf")!.text)).toEqual(["Rechnung 42"]);
    // Stored text with the same hash: the upload is a no-op again.
    expect((await upload(a, ["Anders gelesen"])).data).toEqual({ id: data.id, status: "pending" });
    expect(JSON.parse(docByPath("scan.pdf")!.text)).toEqual(["Rechnung 42"]);
  });

  it("brings a missing document back with the same file, keeping its text, chunks and card", async () => {
    const { upload, manifest } = await setup();
    const ready = file("ready.pdf");
    const pending = file("pending.pdf");
    const other = file("other.pdf");
    const r = await upload(ready, ["Alt"]);
    const p = await upload(pending, ["Wartet"]);
    await upload(other);
    index(r.data.id, [{ page: 1, text: "Alt" }]);
    db.update(kbDocuments).set({ summary: "Karte" }).where(eq(kbDocuments.id, r.data.id)).run();
    db.update(kbDocuments).set({ attempts: 2 }).where(eq(kbDocuments.id, p.data.id)).run();
    await manifest([other]);
    expect(docByPath("ready.pdf")!.status).toBe("missing");

    expect((await upload({ ...ready, tags: ["Neu"] }, ["Anders"])).data).toEqual({ id: r.data.id, status: "ready" });
    const row = docByPath("ready.pdf")!;
    expect(row).toMatchObject({ status: "ready", missingSince: null, summary: "Karte" });
    expect(JSON.parse(row.text)).toEqual(["Alt"]);
    expect(JSON.parse(row.tags)).toEqual(["Neu"]);
    expect(db.select().from(kbChunks).where(eq(kbChunks.documentId, r.data.id)).all()).toHaveLength(1);

    expect((await upload(pending, ["Wartet"])).data).toEqual({ id: p.data.id, status: "pending" });
    expect(docByPath("pending.pdf")).toMatchObject({ status: "pending", missingSince: null, attempts: 0 });
  });

  it("starts the count of runs again with new text", async () => {
    const { upload } = await setup();
    const { data } = await upload(file("a.pdf", "v1"));
    db.update(kbDocuments).set({ attempts: 2, runToken: "t" }).where(eq(kbDocuments.id, data.id)).run();
    await upload(file("a.pdf", "v2"), ["Neu"]);
    expect(docByPath("a.pdf")).toMatchObject({ status: "pending", attempts: 0, runToken: null });
  });

  it("limits the text", async () => {
    const { upload } = await setup();
    expect((await upload(file("big.pdf"), ["x".repeat(MAX_TEXT_BYTES + 1)])).status).toBe(413);
    expect((await upload(file("many.pdf"), Array.from({ length: 2001 }, () => ""))).status).toBe(413);
    expect((await upload(file("ok.pdf"), ["ä".repeat(MAX_TEXT_BYTES / 2)])).status).toBe(202);
    expect((await upload(file("bad.pdf"), [1 as unknown as string])).status).toBe(400);
    expect(docByPath("big.pdf")).toBeUndefined();
  });
});

describe("knowledge: documents", () => {
  async function three() {
    const s = await setup();
    await s.upload(file("Versicherungen/Auto/Allianz.pdf", "1", { tags: ["Auto", "Versicherung"], mtime: 3000 }));
    await s.upload(file("Versicherungen/Hausrat.pdf", "2", { tags: ["Versicherung"], mtime: 2000 }));
    await s.upload(file("Arzt/Befund 100%.pdf", "3", { tags: ["Gesundheit"], mtime: 1000 }));
    return s;
  }
  const names = (data: { documents: { name: string }[] }) => data.documents.map((d) => d.name);

  it("lists newest first with filters", async () => {
    const { edit } = await three();
    const all = await edit("GET", "/knowledge/documents");
    expect(names(all.data)).toEqual(["Allianz.pdf", "Hausrat.pdf", "Befund 100%.pdf"]);
    expect(all.data.nextCursor).toBeNull();
    expect(all.data.documents[0]).toEqual({
      id: expect.any(String),
      folderId: expect.any(String),
      path: "Versicherungen/Auto/Allianz.pdf",
      name: "Allianz.pdf",
      tags: ["Auto", "Versicherung"],
      size: 1,
      mtime: 3000,
      hash: sha("1"),
      pages: 1,
      status: "pending",
      error: null,
      summary: null,
      docDate: null,
      person: null,
      indexedAt: null,
      missingSince: null,
      createdAt: NOW.toISOString(),
      updatedAt: NOW.toISOString(),
    });
    expect(names((await edit("GET", "/knowledge/documents?q=hausrat")).data)).toEqual(["Hausrat.pdf"]);
    expect(names((await edit("GET", "/knowledge/documents?q=gesund")).data)).toEqual(["Befund 100%.pdf"]);
    expect(names((await edit("GET", "/knowledge/documents?q=100%25")).data)).toEqual(["Befund 100%.pdf"]);
    expect(names((await edit("GET", "/knowledge/documents?q=%25")).data)).toEqual(["Befund 100%.pdf"]);
    expect(names((await edit("GET", "/knowledge/documents?tag=Versicherung")).data)).toEqual(["Allianz.pdf", "Hausrat.pdf"]);
    expect(names((await edit("GET", "/knowledge/documents?tag=Versich")).data)).toEqual([]);
    expect(names((await edit("GET", "/knowledge/documents?folder=Versicherungen")).data)).toEqual(["Allianz.pdf", "Hausrat.pdf"]);
    expect(names((await edit("GET", "/knowledge/documents?folder=/Versicherungen/Auto/")).data)).toEqual(["Allianz.pdf"]);
    expect(names((await edit("GET", "/knowledge/documents?folder=Versicherung")).data)).toEqual([]);
    expect((await edit("GET", "/knowledge/documents?folder=../x")).status).toBe(400);
    expect((await edit("GET", "/knowledge/documents?status=nope")).status).toBe(400);
    expect((await edit("GET", "/knowledge/documents?limit=0")).status).toBe(400);
    expect((await edit("GET", "/knowledge/documents?cursor=garbage")).status).toBe(400);
  });

  it("pages with a cursor", async () => {
    const { edit, upload } = await three();
    await upload(file("same-time.pdf", "4", { mtime: 2000 }));
    const seen: string[] = [];
    let cursor: string | null = null;
    do {
      const res: { data: { documents: { name: string }[]; nextCursor: string | null } } = await edit(
        "GET",
        `/knowledge/documents?limit=2${cursor ? `&cursor=${cursor}` : ""}`,
      );
      expect(res.data.documents.length).toBeLessThanOrEqual(2);
      seen.push(...names(res.data));
      cursor = res.data.nextCursor;
    } while (cursor);
    expect(seen).toHaveLength(4);
    expect(new Set(seen).size).toBe(4);
    expect(seen[0]).toBe("Allianz.pdf");
    expect(seen[3]).toBe("Befund 100%.pdf");
  });

  it("excludes and lets back in, reindexes, and counts tags", async () => {
    const { edit } = await three();
    const id = docByPath("Versicherungen/Hausrat.pdf")!.id;
    index(id, [{ page: 1, text: "Hausrat" }]);

    const ex = await edit("POST", `/knowledge/documents/${id}/exclude`, { excluded: true });
    expect(ex.data.document).toMatchObject({ id, status: "excluded", indexedAt: null });
    expect(db.select().from(kbChunks).all()).toHaveLength(0);
    expect(names((await edit("GET", "/knowledge/documents")).data)).toEqual(["Allianz.pdf", "Befund 100%.pdf"]);
    expect(names((await edit("GET", "/knowledge/documents?status=excluded")).data)).toEqual(["Hausrat.pdf"]);
    expect((await edit("GET", "/knowledge/tags")).data).toEqual({
      tags: [
        { tag: "Auto", count: 1 },
        { tag: "Gesundheit", count: 1 },
        { tag: "Versicherung", count: 1 },
      ],
    });
    expect((await edit("POST", `/knowledge/documents/${id}/reindex`)).status).toBe(409);
    expect((await edit("POST", `/knowledge/documents/${id}/exclude`, {})).status).toBe(400);

    const back = await edit("POST", `/knowledge/documents/${id}/exclude`, { excluded: false });
    expect(back.data.document.status).toBe("pending");
    expect(JSON.parse(docByPath("Versicherungen/Hausrat.pdf")!.text)).toEqual(["text"]);
    expect((await edit("GET", "/knowledge/tags")).data.tags[0]).toEqual({ tag: "Versicherung", count: 2 });

    index(id, [{ page: 1, text: "Hausrat" }]);
    const re = await edit("POST", `/knowledge/documents/${id}/reindex`);
    expect(re).toMatchObject({ status: 202, data: { document: { id, status: "pending", indexedAt: null } } });
    // The chunks stay until the worker replaces them.
    expect(db.select().from(kbChunks).all()).toHaveLength(1);
    expect((await edit("POST", "/knowledge/documents/nope/reindex")).status).toBe(404);
  });

  it("shows a document with its card and chunks", async () => {
    const { edit } = await three();
    const id = docByPath("Versicherungen/Hausrat.pdf")!.id;
    index(id, [
      { page: 1, text: "Erster Teil" },
      { page: 2, text: "Zweiter Teil" },
    ]);
    db.update(kbDocuments)
      .set({ summary: "Hausratversicherung", facts: JSON.stringify([{ fact: "Beitrag 80 €", quote: "80 €" }]), docDate: "2026-01-01", personUserId: editorId })
      .where(eq(kbDocuments.id, id))
      .run();
    const { status, data } = await edit("GET", `/knowledge/documents/${id}`);
    expect(status).toBe(200);
    expect(data.document).toMatchObject({
      id,
      status: "ready",
      summary: "Hausratversicherung",
      facts: [{ fact: "Beitrag 80 €", quote: "80 €" }],
      docDate: "2026-01-01",
      person: { id: editorId, name: "Anna", account: true },
      chunks: [
        { id: expect.any(Number), seq: 0, page: 1, text: "Erster Teil" },
        { id: expect.any(Number), seq: 1, page: 2, text: "Zweiter Teil" },
      ],
    });
    expect(data.document.text).toBeUndefined();
    expect((await edit("GET", "/knowledge/documents/nope")).status).toBe(404);
  });

  it("moves a person's documents to their account and clears a leaving member's", async () => {
    const { upload } = await setup();
    const { data } = await upload(file("a.pdf"));
    const { person, invite } = addPerson(db, { id: editorId }, familyId, { name: "Leo", invite: "viewer" }, NOW);
    db.update(kbDocuments).set({ personPersonId: person.id }).where(eq(kbDocuments.id, data.id)).run();
    const leo = makeUser(db, { name: "Leo" });
    acceptInvite(db, leo.id, invite!.code, NOW);
    expect(docByPath("a.pdf")).toMatchObject({ personUserId: leo.id, personPersonId: null });
    removeMember(db, { id: editorId }, familyId, leo.id);
    expect(docByPath("a.pdf")).toMatchObject({ personUserId: null, personPersonId: null });
  });

  it("deletes documents missing for 30 days", async () => {
    const { manifest, upload, edit } = await setup();
    await upload(file("gone.pdf"));
    const { data } = await upload(file("excluded.pdf"));
    await upload(file("here.pdf"));
    await edit("POST", `/knowledge/documents/${data.id}/exclude`, { excluded: true });
    await manifest([file("here.pdf")]);
    const id = docByPath("gone.pdf")!.id;
    index(id, [{ page: 1, text: "gone" }]);
    db.update(kbDocuments).set({ status: "missing" }).where(eq(kbDocuments.id, id)).run();

    expect(cleanup(db, new Date(NOW.getTime() + 29 * DAY)).documents).toBe(0);
    process.env.DISABLED_MODULES = "knowledge";
    expect(cleanup(db, new Date(NOW.getTime() + 31 * DAY)).documents).toBe(0);
    delete process.env.DISABLED_MODULES;
    expect(cleanup(db, new Date(NOW.getTime() + 31 * DAY)).documents).toBe(2);
    expect(db.select({ path: kbDocuments.path }).from(kbDocuments).all()).toEqual([{ path: "here.pdf" }]);
    expect(db.select().from(kbChunks).all()).toHaveLength(0);
  });
});

describe("knowledge: writes", () => {
  it("read and write in immediate transactions (no SQLITE_BUSY_SNAPSHOT under WAL)", async () => {
    const { edit, folderId, upload, manifest } = await setup();
    const { data } = await upload(file("a.pdf"));
    const spy = vi.spyOn(db, "transaction");
    await manifest([file("a.pdf"), file("b.pdf")]);
    await edit("PUT", "/knowledge/documents", { folderId, ...file("b.pdf"), pages: ["b"] });
    await edit("POST", `/knowledge/documents/${data.id}/reindex`);
    await edit("POST", `/knowledge/documents/${data.id}/exclude`, { excluded: true });
    await edit("POST", `/knowledge/documents/${data.id}/exclude`, { excluded: false });
    expect(spy).toHaveBeenCalledTimes(5);
    for (const [, config] of spy.mock.calls) expect(config).toEqual({ behavior: "immediate" });
    spy.mockRestore();
  });
});

describe("knowledge: search", () => {
  /** A ready document of `family` with one chunk per text. */
  function doc(family: string, path: string, texts: string[], opts: { tags?: string[]; status?: string } = {}) {
    const folderId = ensureFolder(db, family, null, NOW).folder.id;
    const id = `doc-${path}-${family.slice(0, 6)}`;
    db.insert(kbDocuments)
      .values({ id, familyId: family, folderId, path, name: path.split("/").pop()!, hash: sha(path), tags: JSON.stringify(opts.tags ?? []), createdAt: NOW, updatedAt: NOW })
      .run();
    index(id, texts.map((text, i) => ({ page: i + 1, text })));
    if (opts.status) db.update(kbDocuments).set({ status: opts.status }).where(eq(kbDocuments.id, id)).run();
    return id;
  }

  it("turns free text into quoted prefix terms", () => {
    expect(ftsTerms('Kündigung "Vertrag" OR NEAR(x) *')).toEqual(['"Kündigung"*', '"Vertrag"*', '"OR"*', '"NEAR"*', '"x"*']);
    expect(ftsTerms("  ?! ")).toEqual([]);
  });

  it("ignores case and diacritics and matches prefixes", () => {
    const id = doc(familyId, "Strom/Kündigung.pdf", ["Hiermit bestätigen wir die Kündigung Ihres Stromvertrags zum 31.12."]);
    for (const q of ["kundigung", "Kündigung", "KÜNDIGUNG", "kündig", "Ku\u0308ndigung", "bestatigen strom"]) {
      const hits = searchKnowledge(db, familyId, q);
      expect(hits.map((h) => h.documentId), q).toEqual([id]);
    }
    const [hit] = searchKnowledge(db, familyId, "stromvertrag");
    expect(hit).toEqual({
      chunkId: expect.any(Number),
      documentId: id,
      name: "Kündigung.pdf",
      path: "Strom/Kündigung.pdf",
      page: 1,
      text: "Hiermit bestätigen wir die Kündigung Ihres Stromvertrags zum 31.12.",
      snippet: expect.stringContaining("**Stromvertrags**"),
    });
    expect(searchKnowledge(db, familyId, "Gaszähler")).toEqual([]);
    expect(searchKnowledge(db, familyId, "")).toEqual([]);
  });

  it("wants every word, else any, best first", () => {
    const both = doc(familyId, "both.pdf", ["Die Hausrat Versicherung kostet 80 Euro"]);
    const one = doc(familyId, "one.pdf", ["Die Kfz Versicherung"]);
    expect(searchKnowledge(db, familyId, "hausrat versicherung").map((h) => h.documentId)).toEqual([both]);
    const any = searchKnowledge(db, familyId, "hausrat kfz");
    expect(any.map((h) => h.documentId).sort()).toEqual([both, one].sort());
  });

  it("finds only the family's ready (and reindexing) documents, with its filters", () => {
    const ready = doc(familyId, "Auto/ready.pdf", ["Zahnarzt Termin"], { tags: ["Gesundheit"] });
    doc(familyId, "missing.pdf", ["Zahnarzt Befund"], { status: "missing" });
    doc(familyId, "failed.pdf", ["Zahnarzt Rechnung"], { status: "failed" });
    doc(familyId, "excluded.pdf", ["Zahnarzt Mahnung"], { status: "excluded" });
    const otherFamily = makeFamily(db, makeUser(db).id).id;
    doc(otherFamily, "other.pdf", ["Zahnarzt Brief"]);
    expect(searchKnowledge(db, familyId, "zahnarzt").map((h) => h.documentId)).toEqual([ready]);
    expect(searchKnowledge(db, familyId, "zahnarzt", { tags: ["Gesundheit"] })).toHaveLength(1);
    expect(searchKnowledge(db, familyId, "zahnarzt", { tags: ["Auto"] })).toHaveLength(0);
    expect(searchKnowledge(db, familyId, "zahnarzt", { folder: "Auto" })).toHaveLength(1);
    expect(searchKnowledge(db, familyId, "zahnarzt", { folder: "Haus" })).toHaveLength(0);
    expect(searchKnowledge(db, otherFamily, "zahnarzt").map((h) => h.name)).toEqual(["other.pdf"]);
  });

  it("still finds a document while its reindex waits", async () => {
    const id = doc(familyId, "a.pdf", ["Kündigungsfrist drei Monate"]);
    const edit = call(editorId);
    expect((await edit("POST", `/knowledge/documents/${id}/reindex`)).status).toBe(202);
    expect(docByPath("a.pdf")!.status).toBe("pending");
    expect(searchKnowledge(db, familyId, "kundigungsfrist").map((h) => h.documentId)).toEqual([id]);
  });

  it("keeps the FTS index in step with the chunks", () => {
    const id = doc(familyId, "a.pdf", ["Alpha Beta"]);
    db.update(kbChunks).set({ text: "Gamma Delta" }).where(eq(kbChunks.documentId, id)).run();
    expect(searchKnowledge(db, familyId, "alpha")).toEqual([]);
    expect(searchKnowledge(db, familyId, "gamma")).toHaveLength(1);
    db.delete(kbDocuments).where(eq(kbDocuments.id, id)).run();
    expect(db.all(sql`select rowid from kb_chunks_fts where kb_chunks_fts match 'gamma'`)).toEqual([]);
    db.run(sql`insert into kb_chunks_fts(kb_chunks_fts, rank) values('integrity-check', 1)`);
  });
});
