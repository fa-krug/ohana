// Recipe imports in the background (lib/meals/ai/import-queue.ts): POST …/meals/recipes/import
// with `background: true` saves a row, the worker's ImportRunner imports it (recipe saved TO_TRY,
// row gone, a push to the starter's devices), failures stay for retry / delete, leases that ran
// out are run again or given up, and the preview reads a page without the AI. Pages come from a
// fake fetch, the AI is the mock, the relay a fake; nothing touches the network.

import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createFamilyApi } from "@/lib/api/family-api";
import { handleAi } from "@/lib/assistant/routes";
import { createToken } from "@/lib/auth/tokens";
import type { Db } from "@/lib/db";
import { aiSettings, recipeImports, recipes, units, users } from "@/lib/db/schema";
import { cleanup } from "@/lib/maintenance/cleanup";
import { ImportRunner } from "@/lib/meals/ai/import-queue";
import { createMealsApp } from "@/lib/meals/app-routes";
import { DEFAULT_PUSH_RELAY_URL } from "@/lib/push/config";
import { registerDevice } from "@/lib/push/devices";
import { openPayload } from "@/lib/push/payload";
import type { RelayClient, RelayMessage } from "@/lib/push/relay";
import { BASE, type AssistantTest, assistantTest, configure, fakeFetch, net } from "@/lib/test/assistant";
import { NOW } from "@/lib/test/factories";
import { MOCK_PNG } from "@/lib/test/mock-ai";

type Res = { status: number; data: any }; // eslint-disable-line @typescript-eslint/no-explicit-any

const PAGE = readFileSync(join(__dirname, "fixtures/meals/recipe-page.html"), "utf8");
const PAGE_URL = "https://kitchen.test/recipes/tomato-soup";
const SLOW_URL = "https://kitchen.test/slow";

/** Lets the slow page answer. */
let openGate: () => void = () => {};
let gate: Promise<void>;

const pageFetch = ((input: string | URL | Request, init?: RequestInit) => {
  const url = new URL(input instanceof Request ? input.url : String(input));
  const html = (body: string) => new Response(body, { headers: { "content-type": "text/html; charset=utf-8" } });
  if (url.hostname === "kitchen.test") {
    net.requests.push(url.href);
    if (url.pathname === "/recipes/tomato-soup") return Promise.resolve(html(PAGE));
    if (url.pathname === "/about") return Promise.resolve(html("<html><head><title>About us</title></head><body><p>We are a small team of cooks.</p></body></html>"));
    if (url.pathname === "/slow") {
      return new Promise<Response>((resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(init.signal!.reason));
        void gate.then(() => resolve(html(PAGE)));
      });
    }
    if (url.pathname.startsWith("/images/")) {
      return Promise.resolve(new Response(Buffer.from(MOCK_PNG, "base64"), { headers: { "content-type": "image/png" } }));
    }
    return Promise.resolve(new Response("gone", { status: 404 }));
  }
  return fakeFetch(input, init);
}) as typeof fetch;

const keyOf = (n: number) => Buffer.alloc(32, n);

function fakeRelay() {
  const messages: RelayMessage[] = [];
  const client: RelayClient = {
    async send(_url, batch) {
      messages.push(...batch);
      return batch.map(() => ({ status: "ok" as const }));
    },
  };
  return { client, messages };
}

let dir: string;
let tests: AssistantTest[] = [];
let runners: ImportRunner[] = [];
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "ohana-import-queue-"));
  process.env.MEDIA_ROOT = dir;
  net.requests = [];
  net.aiBody = null;
  gate = new Promise((r) => (openGate = r));
});
afterEach(async () => {
  openGate();
  await Promise.all(runners.map((r) => r.stop(2000)));
  runners = [];
  delete process.env.MEDIA_ROOT;
  delete process.env.DISABLED_MODULES;
  rmSync(dir, { recursive: true, force: true });
  await Promise.all(tests.map((t) => t.stop()));
  tests = [];
});

function device(db: Db, userId: string, n: number) {
  const { row } = createToken(db, { userId, kind: "api", name: `Device ${n}` }, NOW);
  registerDevice(
    db,
    { id: userId },
    row.id,
    { relay: DEFAULT_PUSH_RELAY_URL, relayToken: `r1.${n}`, key: keyOf(n).toString("base64"), platform: "ios" },
    NOW,
  );
}

function setup(options: { maxConcurrent?: number } = {}) {
  const resolve = () => Promise.resolve(["93.184.216.34"]);
  const t = assistantTest({ worker: false, env: { net: { fetch: pageFetch, resolve } } });
  tests.push(t);
  t.db.insert(units).values([
    { id: 1, nameEn: "gram", nameDe: "Gramm", abbreviation: "g", conversionFactor: "1" },
    { id: 2, nameEn: "piece", nameDe: "Stück", abbreviation: "pc", conversionFactor: "1" },
  ]).run();
  device(t.db, t.editor.id, 1);
  device(t.db, t.viewer.id, 2);
  const relay = fakeRelay();
  const runner = new ImportRunner(t.db, { env: t.env, push: relay.client, maxConcurrent: options.maxConcurrent ?? 2, log: () => {} });
  runners.push(runner);
  const handler = createFamilyApi([createMealsApp({ aiEnv: () => t.env }), handleAi(t.env)], {
    db: t.db,
    appUrl: "http://ohana.test",
    now: () => NOW,
  });
  const as = (token: string) => async (method: string, path: string, body?: unknown): Promise<Res> => {
    const res = await handler(
      new Request(BASE + `/families/${t.familyId}` + path, {
        method,
        headers: { authorization: `Bearer ${token}`, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
        body: body !== undefined ? JSON.stringify(body) : undefined,
      }),
    );
    return { status: res.status, data: await res.json() };
  };
  /** What device `n` got, opened. */
  const received = (n: number) =>
    relay.messages.filter((m) => m.relayToken === `r1.${n}`).map((m) => openPayload(keyOf(n), m.payload));
  /** One tick, then waits for the imports it started. */
  const work = async () => {
    const started = runner.tick();
    await runner.idle(5000);
    return started;
  };
  return { t, call: as(t.editor.token), view: as(t.viewer.token), runner, relay, received, work };
}

const IMPORT = "/meals/recipes/import";
const IMPORTS = "/meals/recipes/imports";
const PREVIEW = "/meals/recipes/import/preview";

async function until(check: () => boolean, ms = 2000) {
  const end = Date.now() + ms;
  while (!check()) {
    if (Date.now() > end) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 5));
  }
}

describe("background imports", () => {
  it("answers 202 at once, lists the import, and the worker saves the recipe TO_TRY", async () => {
    const { t, call, view, received, work } = setup();
    await configure(t);
    const res = await call("POST", IMPORT, { url: PAGE_URL, background: true });
    expect(res).toEqual({
      status: 202,
      data: {
        import: {
          id: expect.any(String),
          url: PAGE_URL,
          title: "",
          imageUrl: null,
          status: "waiting",
          error: null,
          createdAt: NOW.toISOString(),
        },
      },
    });
    // Nothing read yet: the worker does that.
    expect(net.requests).toEqual([]);
    expect(t.db.select().from(recipes).all()).toEqual([]);
    expect((await view("GET", IMPORTS)).data).toEqual({ imports: [res.data.import] });

    expect(await work()).toBe(1);
    expect((await call("GET", IMPORTS)).data).toEqual({ imports: [] });
    const [row] = t.db.select().from(recipes).all();
    expect(row).toMatchObject({ familyId: t.familyId, title: "Grandma's Tomato Soup", listType: "TO_TRY" });
    expect(row.description).toContain(`Source: ${PAGE_URL}`);
    expect(row.image).toMatch(/\.webp$/);
    // Only the account that started it.
    expect(received(2)).toEqual([]);
    expect(received(1)).toEqual([
      {
        v: 1,
        title: "Grandma's Tomato Soup",
        body: "Saved to “Want to try”",
        path: `/f/${t.familyId}/meals/recipes/${row.id}`,
        familyId: t.familyId,
        event: "recipe_imported",
      },
    ]);
  });

  it("keeps the browser's title and text, and lists newest first", async () => {
    const { t, call, work } = setup();
    await configure(t);
    const first = await call("POST", IMPORT, { url: "https://kitchen.test/about", background: true });
    const second = await call("POST", IMPORT, { url: "https://elsewhere.test/soup", text: PAGE, title: "Soup", imageUrl: "https://kitchen.test/images/x.png", background: true });
    expect(second.data.import).toMatchObject({ title: "Soup", imageUrl: "https://kitchen.test/images/x.png" });
    const listed = (await call("GET", IMPORTS)).data.imports;
    expect(listed.map((i: { id: string }) => i.id)).toEqual([second.data.import.id, first.data.import.id]);
    await work();
    // The page's text came along: elsewhere.test was never fetched.
    expect(net.requests).not.toContain("https://elsewhere.test/soup");
    expect(t.db.select({ title: recipes.title }).from(recipes).all()).toEqual([{ title: "Soup" }]);
  });

  it("marks a failed import, tells the starter in their language, retries and deletes it", async () => {
    const { t, call, received, work } = setup();
    await configure(t);
    t.db.update(users).set({ preferredLanguage: "de" }).where(eq(users.id, t.editor.id)).run();
    const { data } = await call("POST", IMPORT, { url: "https://kitchen.test/about", background: true });
    await work();
    const failed = { ...data.import, title: "About us", status: "failed", error: "No recipe found on that page" };
    expect((await call("GET", IMPORTS)).data).toEqual({ imports: [failed] });
    expect(t.db.select().from(recipes).all()).toEqual([]);
    expect(received(1)).toEqual([
      {
        v: 1,
        title: "Rezept konnte nicht importiert werden",
        body: "No recipe found on that page · kitchen.test",
        path: `/f/${t.familyId}/meals/recipes`,
        familyId: t.familyId,
        event: "recipe_imported",
      },
    ]);
    expect(received(2)).toEqual([]);

    const retried = await call("POST", `${IMPORTS}/${data.import.id}/retry`);
    expect(retried).toEqual({ status: 200, data: { import: { ...failed, status: "waiting", error: null } } });
    expect(t.db.select().from(recipeImports).get()).toMatchObject({ attempts: 0, runToken: null, lockedUntil: null });
    expect(await call("POST", `${IMPORTS}/${data.import.id}/retry`)).toEqual({
      status: 409,
      data: { error: "Only a failed import can be retried" },
    });

    expect(await call("DELETE", `${IMPORTS}/${data.import.id}`)).toEqual({ status: 200, data: { deleted: true } });
    expect((await call("GET", IMPORTS)).data).toEqual({ imports: [] });
    expect((await call("DELETE", `${IMPORTS}/${data.import.id}`)).status).toBe(404);
    expect((await call("POST", `${IMPORTS}/${data.import.id}/retry`)).status).toBe(404);
  });

  it("fails when the AI was taken away meanwhile", async () => {
    const { t, call, work } = setup();
    await configure(t);
    await call("POST", IMPORT, { url: PAGE_URL, background: true });
    t.db.delete(aiSettings).run();
    await work();
    expect((await call("GET", IMPORTS)).data.imports[0]).toMatchObject({
      status: "failed",
      error: "The AI isn't set up yet (Settings → AI)",
    });
  });

  it("has the sync import's checks up front", async () => {
    const { t, call, view } = setup();
    expect(await call("POST", IMPORT, { url: PAGE_URL, background: true })).toEqual({
      status: 400,
      data: { error: "The AI isn't set up yet (Settings → AI)" },
    });
    await configure(t);
    expect(await call("POST", IMPORT, { background: true })).toEqual({ status: 400, data: { error: "url is required" } });
    expect((await view("POST", IMPORT, { url: PAGE_URL, background: true })).status).toBe(403);
    expect(t.db.select().from(recipeImports).all()).toEqual([]);
  });

  it("lets viewers look, not change", async () => {
    const { t, call, view } = setup();
    await configure(t);
    const { data } = await call("POST", IMPORT, { url: PAGE_URL, background: true });
    expect((await view("GET", IMPORTS)).status).toBe(200);
    expect((await view("DELETE", `${IMPORTS}/${data.import.id}`)).status).toBe(403);
    expect((await view("POST", `${IMPORTS}/${data.import.id}/retry`)).status).toBe(403);
    expect((await view("POST", PREVIEW, { url: PAGE_URL })).status).toBe(403);
    expect(t.db.select().from(recipeImports).all()).toHaveLength(1);
  });

  it("is off with the assistant", async () => {
    const { t, call, runner } = setup();
    await configure(t);
    await call("POST", IMPORT, { url: PAGE_URL, background: true });
    process.env.DISABLED_MODULES = "assistant";
    expect(await call("POST", IMPORT, { url: PAGE_URL, background: true })).toEqual({
      status: 404,
      data: { error: "The assistant is turned off on this server" },
    });
    expect((await call("POST", PREVIEW, { url: PAGE_URL })).status).toBe(404);
    expect((await call("GET", IMPORTS)).data).toEqual({ imports: [] });
    expect(runner.tick()).toBe(0);
  });

  it("runs at most maxConcurrent at once", async () => {
    const { t, call, runner, work } = setup({ maxConcurrent: 2 });
    await configure(t);
    for (let i = 0; i < 3; i++) await call("POST", IMPORT, { url: SLOW_URL, background: true });
    expect(runner.tick()).toBe(2);
    expect(runner.active).toBe(2);
    const statuses = (await call("GET", IMPORTS)).data.imports.map((i: { status: string }) => i.status).sort();
    expect(statuses).toEqual(["running", "running", "waiting"]);
    openGate();
    await work();
    await runner.idle(5000);
    expect(t.db.select().from(recipes).all()).toHaveLength(3);
    expect(t.db.select().from(recipeImports).all()).toEqual([]);
  });

  it("drops a running import that was deleted, without a recipe or a push", async () => {
    const { t, call, runner, relay } = setup();
    await configure(t);
    const { data } = await call("POST", IMPORT, { url: SLOW_URL, background: true });
    runner.tick();
    await until(() => net.requests.includes(SLOW_URL));
    await call("DELETE", `${IMPORTS}/${data.import.id}`);
    runner.tick(); // notices it's gone and aborts the run
    await runner.idle(5000);
    expect(runner.active).toBe(0);
    openGate();
    expect(t.db.select().from(recipes).all()).toEqual([]);
    expect(t.db.select().from(recipeImports).all()).toEqual([]);
    expect(relay.messages).toEqual([]);
  });

  it("runs an import whose worker went away once more, then gives up", async () => {
    const { t, call, received, work } = setup();
    await configure(t);
    const { data } = await call("POST", IMPORT, { url: PAGE_URL, background: true });
    const lost = { status: "running", runToken: "gone", lockedUntil: new Date(Date.now() - 1000) };
    t.db.update(recipeImports).set({ ...lost, attempts: 1 }).run();
    expect(await work()).toBe(1);
    expect(t.db.select().from(recipes).all()).toHaveLength(1);
    expect(t.db.select().from(recipeImports).all()).toEqual([]);

    // A lease not yet run out stays with its worker.
    const second = await call("POST", IMPORT, { url: PAGE_URL, background: true });
    t.db.update(recipeImports).set({ ...lost, lockedUntil: new Date(Date.now() + 60_000), attempts: 1 }).run();
    expect(await work()).toBe(0);
    // Ran twice already: failed.
    t.db.update(recipeImports).set({ ...lost, attempts: 2 }).run();
    expect(await work()).toBe(0);
    expect((await call("GET", IMPORTS)).data.imports).toEqual([
      { ...second.data.import, status: "failed", error: "The import was interrupted" },
    ]);
    expect(received(1).map((p) => p.title)).toEqual(["Grandma's Tomato Soup", "Couldn't import the recipe"]);
    expect(data.import.id).not.toBe(second.data.import.id);
  });

  it("lets go of its imports when the worker stops", async () => {
    const { t, call, runner } = setup();
    await configure(t);
    await call("POST", IMPORT, { url: SLOW_URL, background: true });
    runner.tick();
    await until(() => net.requests.includes(SLOW_URL));
    await runner.stop(2000);
    expect(t.db.select().from(recipeImports).get()).toMatchObject({ status: "waiting", attempts: 0, runToken: null, lockedUntil: null });
    expect(t.db.select().from(recipes).all()).toEqual([]);
  });

  it("removes failed imports after a week", async () => {
    const { t, call, work } = setup();
    await configure(t);
    await call("POST", IMPORT, { url: "https://kitchen.test/about", background: true });
    await call("POST", IMPORT, { url: SLOW_URL, background: true });
    t.db.update(recipeImports).set({ status: "failed", updatedAt: NOW }).where(eq(recipeImports.url, "https://kitchen.test/about")).run();
    expect(cleanup(t.db, new Date(NOW.getTime() + 6 * 86_400_000)).imports).toBe(0);
    expect(cleanup(t.db, new Date(NOW.getTime() + 8 * 86_400_000)).imports).toBe(1);
    expect(t.db.select({ url: recipeImports.url }).from(recipeImports).all()).toEqual([{ url: SLOW_URL }]);
    openGate();
    await work();
  });
});

describe("POST /meals/recipes/import/preview", () => {
  const ld = (extra = "") =>
    `<html><head><title>Page title</title><meta property="og:title" content="OG title">${extra}` +
    `<script type="application/ld+json">{"@type":"Recipe","name":"Lentil Stew","image":"/img/stew.jpg"}</script></head>` +
    `<body><p>${"Lentils, carrots and a long simmer. ".repeat(5)}</p></body></html>`;

  it("finds Recipe data in the browser's HTML, without the AI", async () => {
    const { t, call } = setup();
    await configure(t);
    expect(await call("POST", PREVIEW, { url: "https://elsewhere.test/stew", text: ld(), title: "Shared title" })).toEqual({
      status: 200,
      data: { recipe: true, title: "Lentil Stew", imageUrl: "https://elsewhere.test/img/stew.jpg" },
    });
    // The browser's photo wins.
    const withPhoto = await call("POST", PREVIEW, { url: "https://elsewhere.test/stew", text: ld(), imageUrl: "https://cdn.test/p.jpg" });
    expect(withPhoto.data.imageUrl).toBe("https://cdn.test/p.jpg");
    expect(net.aiBody).toBeNull();
    expect(net.requests).toEqual([]);
  });

  it("says no recipe for a page without Recipe data", async () => {
    const { call } = setup();
    const page = "<html><head><title>About us</title></head><body><p>" + "We are a small team of cooks. ".repeat(5) + "</p></body></html>";
    expect((await call("POST", PREVIEW, { url: "https://elsewhere.test/about", text: page })).data).toEqual({
      recipe: false,
      title: "About us",
      imageUrl: null,
    });
    expect((await call("POST", PREVIEW, { url: "https://elsewhere.test/about", text: page, title: "Shared" })).data.title).toBe("Shared");
    // Plain text: no recipe data, the browser's title.
    expect((await call("POST", PREVIEW, { url: "https://elsewhere.test/x", text: "x".repeat(200) })).data).toEqual({
      recipe: false,
      title: "",
      imageUrl: null,
    });
  });

  it("fetches the page without the browser's text", async () => {
    const { call } = setup();
    expect(await call("POST", PREVIEW, { url: PAGE_URL })).toEqual({
      status: 200,
      data: { recipe: true, title: "Grandma's Tomato Soup", imageUrl: "https://kitchen.test/images/soup-large.jpg" },
    });
    expect(net.requests).toEqual([PAGE_URL]);
    expect(await call("POST", PREVIEW, { url: "https://kitchen.test/missing" })).toEqual({
      status: 502,
      data: { error: "The page answered 404" },
    });
    expect((await call("POST", PREVIEW, { url: "http://127.0.0.1/x" })).status).toBe(400);
  });
});
