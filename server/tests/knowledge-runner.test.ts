// The worker's KnowledgeRunner (lib/knowledge/runner.ts): pending documents become ready with
// their chunks (and searchable), new text / reindex chunk again, a run that lost its lease (new
// upload, excluded, missing) writes nothing, excluded and missing documents are never claimed, at
// most N run at once, a lost lease is run again once and then failed, failures keep the reason,
// a turned-off module does nothing, and every chunk stays in its family.

import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { asc, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { kbChunks, kbDocuments } from "@/lib/db/schema";
import { createFamilyApi } from "@/lib/api/family-api";
import { handleDisabledModules } from "@/lib/api/disabled-modules";
import { createToken } from "@/lib/auth/tokens";
import { chunkPages, type TextChunk } from "@/lib/knowledge/chunk";
import { handleKnowledge } from "@/lib/knowledge/routes";
import { MISSING_GRACE_MS } from "@/lib/knowledge/manifest";
import { KNOWLEDGE_LEASE_MS, KnowledgeRunner, type KnowledgeRunnerOptions } from "@/lib/knowledge/runner";
import { searchKnowledge } from "@/lib/knowledge/search";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const BASE = "http://ohana.test/api/v1";

let db: Db;
let editorId: string;
let familyId: string;
let now: Date;
let runners: KnowledgeRunner[];
let logs: string[];

function call(userId: string, family: string) {
  const handler = createFamilyApi([handleDisabledModules, handleKnowledge], { db, appUrl: "http://ohana.test", now: () => now });
  const token = createToken(db, { userId, kind: "api" }, NOW).token;
  return async (method: string, path: string, body?: unknown) => {
    const res = await handler(
      new Request(BASE + `/families/${family}` + path, {
        method,
        headers: { authorization: `Bearer ${token}`, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
        body: body !== undefined ? JSON.stringify(body) : undefined,
      }),
    );
    return { status: res.status, data: await res.json() };
  };
}

const sha = (s: string) => createHash("sha256").update(s).digest("hex");

/** The family's folder, and uploads, manifests and actions on documents through the API. */
async function setup(userId = editorId, family = familyId) {
  const edit = call(userId, family);
  const folderId = (await edit("POST", "/knowledge/folder")).data.folder.id as string;
  const upload = async (path: string, pages: string[]) => {
    const res = await edit("PUT", "/knowledge/documents", {
      folderId,
      path,
      size: 1,
      mtime: 1_700_000_000_000,
      hash: sha(JSON.stringify(pages)),
      tags: [],
      pages,
    });
    expect(res.status).toBe(202);
    return res.data.id as string;
  };
  const manifest = (paths: string[]) =>
    edit("POST", "/knowledge/manifest", {
      folderId,
      files: paths.map((path) => ({ path, size: 1, mtime: 1_700_000_000_000, hash: sha(path), tags: [] })),
    });
  /** `paths` as the manifest now and once the grace is over: the documents left out are missing. */
  const untilMissing = async (paths: string[]) => {
    await manifest(paths);
    now = new Date(now.getTime() + MISSING_GRACE_MS);
    return manifest(paths);
  };
  return { edit, folderId, upload, manifest, untilMissing };
}

function runner(opts: KnowledgeRunnerOptions = {}) {
  const r = new KnowledgeRunner(db, { now: () => now, log: (m) => logs.push(m), ...opts });
  runners.push(r);
  return r;
}

/** Ticks and waits until the runs (and the ones they started) ended. */
async function drain(r: KnowledgeRunner) {
  r.tick();
  await r.idle(5000);
}

function doc(id: string) {
  return db.select().from(kbDocuments).where(eq(kbDocuments.id, id)).get()!;
}

function chunksOf(id: string) {
  return db.select().from(kbChunks).where(eq(kbChunks.documentId, id)).orderBy(asc(kbChunks.seq)).all();
}

/** A chunker whose calls wait until `open()`; `calls` holds the pages each one got. */
function gatedChunker() {
  const calls: string[][] = [];
  const waiting: (() => void)[] = [];
  let opened = false;
  const chunker = async (pages: string[]): Promise<TextChunk[]> => {
    calls.push(pages);
    if (!opened) await new Promise<void>((resolve) => waiting.push(resolve));
    return chunkPages(pages);
  };
  const open = () => {
    opened = true;
    for (const resolve of waiting.splice(0)) resolve();
  };
  /** Lets the waiting calls go, but keeps later ones waiting. */
  const release = () => {
    for (const resolve of waiting.splice(0)) resolve();
  };
  return { chunker, calls, open, release, waiting };
}

/** Until the event loop turned (the runs reach their chunker after a setImmediate). */
const turn = () => new Promise((resolve) => setImmediate(resolve));

beforeEach(() => {
  db = createTestDb();
  now = NOW;
  runners = [];
  logs = [];
  editorId = makeUser(db, { name: "Anna" }).id;
  familyId = makeFamily(db, editorId).id;
});

afterEach(async () => {
  delete process.env.DISABLED_MODULES;
  await Promise.all(runners.map((r) => r.stop(1000)));
});

describe("knowledge runner: indexing", () => {
  it("makes a pending upload ready with its chunks, then it is found", async () => {
    const { upload, edit } = await setup();
    const long = Array.from({ length: 30 }, (_, i) => `Absatz ${i}: Die Hausratversicherung deckt Schäden bis 50 000 €.`).join("\n\n");
    const id = await upload("Versicherungen/Hausrat.pdf", ["Kündigungsfrist: drei Monate zum Jahresende.", "", long]);
    expect(searchKnowledge(db, familyId, "Kündigungsfrist")).toEqual([]);
    now = new Date(NOW.getTime() + 60_000);
    await drain(runner());
    const row = doc(id);
    expect(row).toMatchObject({ status: "ready", error: null, runToken: null, runUntil: null, attempts: 1 });
    expect(row.indexedAt).toEqual(now);
    expect(row.updatedAt).toEqual(now);
    const chunks = chunksOf(id);
    expect(chunks.length).toBeGreaterThan(2);
    expect(chunks[0]).toMatchObject({ seq: 0, page: 1, familyId, text: "Kündigungsfrist: drei Monate zum Jahresende." });
    expect(chunks.slice(1).every((c) => c.page === 3)).toBe(true);
    expect(chunks.map((c) => c.seq)).toEqual(chunks.map((_, i) => i));
    const hits = searchKnowledge(db, familyId, "kundigungsfrist");
    expect(hits).toMatchObject([{ chunkId: chunks[0].id, documentId: id, page: 1, name: "Hausrat.pdf" }]);
    expect(searchKnowledge(db, familyId, "Hausratversicherung").length).toBeGreaterThan(1);
    // The API shows it as the app will.
    const { data } = await edit("GET", `/knowledge/documents/${id}`);
    expect(data.document).toMatchObject({ status: "ready", indexedAt: now.toISOString(), chunks: expect.any(Array) });
    expect(data.document.chunks).toHaveLength(chunks.length);
  });

  it("makes a document without text ready without chunks", async () => {
    const { upload } = await setup();
    const empty = await upload("leer.pdf", []);
    const blank = await upload("scan.pdf", ["", "  \n "]);
    db.update(kbDocuments).set({ text: "" }).where(eq(kbDocuments.id, empty)).run();
    await drain(runner());
    for (const id of [empty, blank]) {
      expect(doc(id)).toMatchObject({ status: "ready", error: null });
      expect(doc(id).indexedAt).not.toBeNull();
      expect(chunksOf(id)).toEqual([]);
    }
  });

  it("replaces the chunks when new text comes", async () => {
    const { upload } = await setup();
    const id = await upload("brief.pdf", ["Alter Inhalt über Zahnarzt."]);
    const r = runner();
    await drain(r);
    expect(searchKnowledge(db, familyId, "Zahnarzt")).toHaveLength(1);
    expect(await upload("brief.pdf", ["Neuer Inhalt über Kieferorthopäde."])).toBe(id);
    expect(doc(id)).toMatchObject({ status: "pending", indexedAt: null, attempts: 0 });
    await drain(r);
    expect(doc(id)).toMatchObject({ status: "ready", attempts: 1 });
    expect(chunksOf(id).map((c) => c.text)).toEqual(["Neuer Inhalt über Kieferorthopäde."]);
    expect(searchKnowledge(db, familyId, "Zahnarzt")).toEqual([]);
    expect(searchKnowledge(db, familyId, "Kieferorthopäde")).toHaveLength(1);
  });

  it("chunks again on reindex", async () => {
    const { upload, edit } = await setup();
    const id = await upload("a.pdf", ["Erste Fassung."]);
    const r = runner();
    await drain(r);
    const before = chunksOf(id);
    // The stored text is what is chunked again (here changed behind the API's back).
    db.update(kbDocuments).set({ text: JSON.stringify(["Zweite Fassung.", "Seite zwei."]) }).where(eq(kbDocuments.id, id)).run();
    expect((await edit("POST", `/knowledge/documents/${id}/reindex`)).status).toBe(202);
    // Until the worker has run, the old chunks stay, and are still found.
    expect(chunksOf(id)).toEqual(before);
    expect(searchKnowledge(db, familyId, "Fassung")).toMatchObject([{ text: "Erste Fassung." }]);
    await drain(r);
    const after = chunksOf(id);
    expect(after.map((c) => [c.page, c.text])).toEqual([
      [1, "Zweite Fassung."],
      [2, "Seite zwei."],
    ]);
    expect(after.some((c) => before.some((b) => b.id === c.id))).toBe(false);
    expect(searchKnowledge(db, familyId, "Fassung")).toMatchObject([{ text: "Zweite Fassung." }]);
  });

  it("keeps every chunk in its family", async () => {
    const otherEditor = makeUser(db, { name: "Carla" }).id;
    const otherFamily = makeFamily(db, otherEditor).id;
    const mine = await setup();
    const theirs = await setup(otherEditor, otherFamily);
    const a = await mine.upload("a.pdf", ["Gemeinsames Wort Apfel."]);
    const b = await theirs.upload("a.pdf", ["Gemeinsames Wort Birne."]);
    await drain(runner());
    expect(chunksOf(a).map((c) => c.familyId)).toEqual([familyId]);
    expect(chunksOf(b).map((c) => c.familyId)).toEqual([otherFamily]);
    expect(searchKnowledge(db, familyId, "Gemeinsames").map((h) => h.documentId)).toEqual([a]);
    expect(searchKnowledge(db, otherFamily, "Gemeinsames").map((h) => h.documentId)).toEqual([b]);
    expect(searchKnowledge(db, familyId, "Birne")).toEqual([]);
  });
});

describe("knowledge runner: leases", () => {
  it("drops the result of a run whose document got new text meanwhile", async () => {
    const { upload } = await setup();
    const id = await upload("a.pdf", ["Alter Text."]);
    const gate = gatedChunker();
    const r = runner({ chunker: gate.chunker });
    expect(r.tick()).toBe(1);
    await turn();
    expect(gate.calls).toEqual([["Alter Text."]]);
    expect(doc(id).runToken).not.toBeNull();
    // A new upload clears the lease; no tick in between, so the old run finishes unaware.
    await upload("a.pdf", ["Neuer Text."]);
    expect(doc(id)).toMatchObject({ status: "pending", runToken: null });
    gate.open();
    await r.idle(5000);
    expect(logs.some((m) => m.includes("changed while it was indexed"))).toBe(true);
    // The run that ended started the next one, with the new text.
    expect(gate.calls).toEqual([["Alter Text."], ["Neuer Text."]]);
    expect(doc(id)).toMatchObject({ status: "ready", attempts: 1 });
    expect(chunksOf(id).map((c) => c.text)).toEqual(["Neuer Text."]);
  });

  it("aborts a run whose lease is gone at the next tick, and writes nothing", async () => {
    const { upload, edit } = await setup();
    const id = await upload("a.pdf", ["Text."]);
    const gate = gatedChunker();
    const r = runner({ chunker: gate.chunker });
    r.tick();
    await turn();
    await edit("POST", `/knowledge/documents/${id}/exclude`, { excluded: true });
    r.tick(); // notices the lost lease
    gate.open();
    await r.idle(5000);
    expect(doc(id)).toMatchObject({ status: "excluded", runToken: null, indexedAt: null });
    expect(chunksOf(id)).toEqual([]);
  });

  it("doesn't bring back a document marked missing while it ran", async () => {
    const { upload, untilMissing } = await setup();
    const id = await upload("a.pdf", ["Text."]);
    const gate = gatedChunker();
    const r = runner({ chunker: gate.chunker });
    r.tick();
    await turn();
    expect((await untilMissing(["other.pdf"])).data).toEqual({ upload: ["other.pdf"] });
    expect(doc(id)).toMatchObject({ status: "missing", runToken: null });
    gate.open();
    await r.idle(5000);
    expect(doc(id)).toMatchObject({ status: "missing", indexedAt: null, error: null });
    expect(chunksOf(id)).toEqual([]);
  });

  it("doesn't mark a document failed when its run failed after losing the lease", async () => {
    const { upload } = await setup();
    const id = await upload("a.pdf", ["Text."]);
    let fail: (err: Error) => void = () => {};
    let calls = 0;
    // The first call fails when told to, later ones chunk.
    const chunker = (pages: string[]) =>
      ++calls === 1 ? new Promise<TextChunk[]>((_, reject) => (fail = reject)) : chunkPages(pages);
    const r = runner({ chunker });
    r.tick();
    await turn();
    await upload("a.pdf", ["Anderer Text."]);
    fail(new Error("boom"));
    await r.idle(5000);
    // The old run wrote nothing; the new text's run made it ready.
    expect(calls).toBe(2);
    expect(doc(id)).toMatchObject({ status: "ready", error: null });
    expect(chunksOf(id).map((c) => c.text)).toEqual(["Anderer Text."]);
  });

  it("never claims excluded, missing, ready or failed documents", async () => {
    const { upload, edit, untilMissing } = await setup();
    const excluded = await upload("excluded.pdf", ["x"]);
    const missing = await upload("missing.pdf", ["x"]);
    const kept = await upload("kept.pdf", ["x"]);
    await edit("POST", `/knowledge/documents/${excluded}/exclude`, { excluded: true });
    await untilMissing(["kept.pdf", "excluded.pdf"]); // missing.pdf is gone
    db.update(kbDocuments).set({ status: "failed", error: "earlier" }).where(eq(kbDocuments.id, kept)).run();
    const gate = gatedChunker();
    const r = runner({ chunker: gate.chunker });
    expect(r.tick()).toBe(0);
    await r.idle(1000);
    expect(gate.calls).toEqual([]);
    expect(doc(excluded)).toMatchObject({ status: "excluded", runToken: null, attempts: 0 });
    expect(doc(missing)).toMatchObject({ status: "missing", runToken: null, attempts: 0 });
    expect(doc(kept)).toMatchObject({ status: "failed", runToken: null, attempts: 0 });
  });

  it("runs at most maxConcurrent at once, then the rest", async () => {
    const { upload } = await setup();
    const ids = [];
    for (let i = 0; i < 5; i++) ids.push(await upload(`d${i}.pdf`, [`Dokument ${i}.`]));
    const gate = gatedChunker();
    const r = runner({ chunker: gate.chunker, maxConcurrent: 2 });
    expect(r.tick()).toBe(2);
    expect(r.active).toBe(2);
    expect(r.tick()).toBe(0);
    await turn();
    expect(gate.calls).toHaveLength(2);
    expect(ids.filter((id) => doc(id).runToken !== null)).toHaveLength(2);
    gate.release();
    await turn();
    await turn();
    // Two ended, the next two started on their own.
    expect(gate.calls).toHaveLength(4);
    expect(r.active).toBe(2);
    gate.open();
    await r.idle(5000);
    expect(ids.map((id) => doc(id).status)).toEqual(["ready", "ready", "ready", "ready", "ready"]);
  });

  it("never runs a document twice across runners", async () => {
    const { upload } = await setup();
    const id = await upload("a.pdf", ["Text."]);
    const gate = gatedChunker();
    const one = runner({ chunker: gate.chunker });
    const two = runner({ chunker: gate.chunker });
    expect(one.tick()).toBe(1);
    expect(two.tick()).toBe(0);
    gate.open();
    await Promise.all([one.idle(5000), two.idle(5000)]);
    expect(gate.calls).toHaveLength(1);
    expect(doc(id)).toMatchObject({ status: "ready", attempts: 1 });
  });

  it("runs a document again when its worker went away, once", async () => {
    const { upload } = await setup();
    const id = await upload("a.pdf", ["Text."]);
    // A worker claimed it and died.
    db.update(kbDocuments)
      .set({ runToken: "dead", runUntil: new Date(NOW.getTime() + KNOWLEDGE_LEASE_MS), attempts: 1 })
      .where(eq(kbDocuments.id, id))
      .run();
    const r = runner();
    // Not while the lease holds.
    expect(r.tick()).toBe(0);
    now = new Date(NOW.getTime() + KNOWLEDGE_LEASE_MS + 1000);
    expect(r.tick()).toBe(1);
    await r.idle(5000);
    expect(logs.some((m) => m.includes("again"))).toBe(true);
    expect(doc(id)).toMatchObject({ status: "ready", attempts: 2, runToken: null });
    expect(chunksOf(id)).toHaveLength(1);
  });

  it("marks a document failed when its run was lost too often", async () => {
    const { upload } = await setup();
    const id = await upload("a.pdf", ["Text."]);
    db.update(kbDocuments)
      .set({ runToken: "dead", runUntil: new Date(NOW.getTime() - 1000), attempts: 2 })
      .where(eq(kbDocuments.id, id))
      .run();
    const r = runner();
    expect(r.tick()).toBe(0);
    expect(doc(id)).toMatchObject({ status: "failed", error: "Indexing was interrupted", indexedAt: null, runToken: null, runUntil: null });
    // A reindex gives it another go.
    const { edit } = await setup();
    await edit("POST", `/knowledge/documents/${id}/reindex`);
    expect(doc(id).attempts).toBe(0);
    await drain(r);
    expect(doc(id)).toMatchObject({ status: "ready", error: null, attempts: 1 });
  });

  it("lets its documents wait again when the worker stops", async () => {
    const { upload } = await setup();
    const id = await upload("a.pdf", ["Text."]);
    const gate = gatedChunker();
    const r = runner({ chunker: gate.chunker });
    r.tick();
    await turn();
    const stopping = r.stop(5000);
    gate.open();
    await stopping;
    expect(doc(id)).toMatchObject({ status: "pending", runToken: null, runUntil: null, attempts: 0 });
    expect(r.tick()).toBe(0);
  });
});

describe("knowledge runner: failures and the module", () => {
  it("marks a document failed with the reason when chunking throws", async () => {
    const { upload, edit } = await setup();
    const id = await upload("a.pdf", ["Text."]);
    const r = runner({
      chunker: () => {
        throw new Error("Chunking broke");
      },
    });
    await drain(r);
    expect(doc(id)).toMatchObject({ status: "failed", error: "Chunking broke", indexedAt: null, runToken: null, runUntil: null });
    expect(chunksOf(id)).toEqual([]);
    const { data } = await edit("GET", `/knowledge/documents/${id}`);
    expect(data.document).toMatchObject({ status: "failed", error: "Chunking broke", indexedAt: null });
    // Not claimed again on its own.
    expect(r.tick()).toBe(0);
  });

  it("marks a document with damaged stored text failed, dropping its old chunks", async () => {
    const { upload, edit } = await setup();
    const id = await upload("a.pdf", ["Erste Fassung."]);
    const r = runner();
    await drain(r);
    expect(chunksOf(id)).toHaveLength(1);
    db.update(kbDocuments).set({ text: "{not json" }).where(eq(kbDocuments.id, id)).run();
    await edit("POST", `/knowledge/documents/${id}/reindex`);
    await drain(r);
    expect(doc(id)).toMatchObject({ status: "failed", indexedAt: null });
    expect(doc(id).error).toEqual(expect.any(String));
    expect(doc(id).error!.length).toBeGreaterThan(0);
    expect(chunksOf(id)).toEqual([]);
    expect(searchKnowledge(db, familyId, "Fassung")).toEqual([]);
  });

  it("does nothing while the module is turned off", async () => {
    const { upload } = await setup();
    const id = await upload("a.pdf", ["Text."]);
    process.env.DISABLED_MODULES = "knowledge";
    const r = runner();
    expect(r.tick()).toBe(0);
    await r.idle(1000);
    expect(doc(id)).toMatchObject({ status: "pending", runToken: null, attempts: 0 });
    expect(chunksOf(id)).toEqual([]);
    delete process.env.DISABLED_MODULES;
    await drain(r);
    expect(doc(id).status).toBe("ready");
  });
});
