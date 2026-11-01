// The assistant under test: the family API with the AI routes on the in-memory database, the
// mock AI (and a few fake web pages and search APIs) behind a fake fetch, and the worker's
// ChatRunner ticking every few milliseconds, so turns run as in production: in the worker.

import { createFamilyApi } from "@/lib/api/family-api";
import { type AiEnv, handleAi } from "@/lib/assistant/routes";
import { ChatRunner } from "@/lib/assistant/runner";
import { DrizzleAssistantStore } from "@/lib/assistant/store";
import { createToken } from "@/lib/auth/tokens";
import { handleFamily } from "@/lib/calendar/family-routes";
import { handleCalendar } from "@/lib/calendar/vacation";
import type { Db } from "@/lib/db";
import { familyMembers } from "@/lib/db/schema";
import { handleFinance } from "@/lib/finance/finance";
import { handleEvents } from "@/lib/calendar/events";
import { handleMeals } from "@/lib/meals/family-routes";
import { handleAppointments } from "@/lib/appointments/family-routes";
import { handleChores } from "@/lib/chores/routes";
import { devSecret, SecretBox } from "@/lib/secrets";
import { createTestDb } from "./db";
import { NOW, makeFamily, makeUser } from "./factories";
import { mockAi } from "./mock-ai";

export const BASE = "http://ohana.test/api/v1";
export const AI = "https://mock.test/v1";
export const KEY = "sk-test-1234567890abcd";

/** What the outside world got: every URL, and the last request body of the mock AI. */
export const net = {
  requests: [] as string[],
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  aiBody: null as any,
};

/** The outside world: the mock AI, a web page, a redirect to a private address, Tavily. */
export const fakeFetch = ((input: string | URL | Request, init?: RequestInit) => {
  const url = new URL(input instanceof Request ? input.url : String(input));
  net.requests.push(url.href);
  if (url.href.startsWith(AI)) {
    net.aiBody = typeof init?.body === "string" ? JSON.parse(init.body) : null;
    return mockAi(new Request(url, init));
  }
  if (url.hostname === "pages.test") {
    if (url.pathname === "/long") {
      return Promise.resolve(
        new Response(`<html><body><p>${"Opening times and prices. ".repeat(300)}</p></body></html>`, {
          headers: { "content-type": "text/html; charset=utf-8" },
        }),
      );
    }
    return Promise.resolve(
      new Response(
        "<html><head><title>School holidays 2027</title><script>evil()</script></head>" +
          "<body><nav>Menu</nav><h1>Bavaria</h1><p>Summer: Aug 2 &ndash; Sep 13</p></body></html>",
        { headers: { "content-type": "text/html; charset=utf-8" } },
      ),
    );
  }
  if (url.hostname === "redirect.test") {
    return Promise.resolve(new Response(null, { status: 302, headers: { location: "http://169.254.169.254/" } }));
  }
  if (url.hostname === "api.tavily.com") {
    const query = JSON.parse(String(init?.body ?? "{}")).query ?? "";
    if (/zorbex/i.test(query)) {
      return Promise.resolve(
        Response.json({ results: [{ title: "Zorbex", url: "https://zorbex.test", content: "A leisure park" }] }),
      );
    }
    return Promise.resolve(
      Response.json({ results: [{ title: "Ferien Bayern 2027", url: "https://pages.test/ferien", content: "…" }] }),
    );
  }
  return Promise.resolve(new Response("not found", { status: 404 }));
}) as typeof fetch;

export type Res = { status: number; data: any; headers: Headers }; // eslint-disable-line @typescript-eslint/no-explicit-any
export type Call = (method: string, path: string, body?: unknown) => Promise<Res>;
export type Event = { event: string; data: any }; // eslint-disable-line @typescript-eslint/no-explicit-any

export function parseEvents(sse: string): Event[] {
  return sse
    .split("\n\n")
    .filter((b) => b.trim())
    .map((block) => ({
      event: /^event: (.*)$/m.exec(block)?.[1] ?? "",
      data: JSON.parse(/^data: (.*)$/m.exec(block)?.[1] ?? "{}"),
    }))
    .filter((e) => e.event !== "ping");
}

export interface AssistantTest {
  db: Db;
  env: AiEnv;
  store: DrizzleAssistantStore;
  handler: (req: Request) => Promise<Response>;
  as: (token: string) => Call;
  call: Call;
  /** The editor's id and API token. */
  editor: { id: string; token: string };
  familyId: string;
  /** Calls as a viewer of the family. */
  view: Call;
  viewer: { id: string; token: string };
  ai: string;
  f: string;
  /** Sends a request without reading the answer (like a closed browser). */
  fire: (method: string, path: string, body: unknown) => Promise<number>;
  /** The worker: started ticking; `stop()` at the end of the test. */
  runner: ChatRunner;
  stop: () => Promise<void>;
}

/** A family with an editor and a viewer; the worker ticks unless `worker: false`. */
export function assistantTest(
  options: { env?: Partial<AiEnv>; worker?: boolean; maxConcurrent?: number } = {},
): AssistantTest {
  const db = createTestDb();
  const store = new DrizzleAssistantStore(db);
  const box = new SecretBox(devSecret());
  const env: AiEnv = {
    db,
    store,
    secrets: () => box,
    net: { fetch: fakeFetch, resolve: () => Promise.resolve(["93.184.216.34"]) },
    modelNet: { fetch: fakeFetch, resolve: () => Promise.resolve(["93.184.216.34"]) },
    pollMs: 5,
    retryMs: 5,
    saveMs: 10,
    heartbeatMs: 100,
    ...options.env,
  };
  const handler = createFamilyApi([handleFamily, handleCalendar, handleEvents, handleFinance, handleMeals, handleAppointments, handleChores, handleAi(env)], {
    db,
    appUrl: "http://ohana.test",
  });
  const as =
    (token: string): Call =>
    async (method, path, body) => {
      const res = await handler(
        new Request(BASE + path, {
          method,
          headers: {
            authorization: `Bearer ${token}`,
            ...(body !== undefined ? { "content-type": "application/json" } : {}),
          },
          body: body !== undefined ? JSON.stringify(body) : undefined,
        }),
      );
      const text = await res.text();
      let data: unknown = text;
      if ((res.headers.get("content-type") ?? "").includes("text/event-stream")) data = parseEvents(text);
      else {
        try {
          data = JSON.parse(text);
        } catch {
          // not JSON
        }
      }
      return { status: res.status, data, headers: res.headers };
    };
  const user = makeUser(db, { email: "editor@test" });
  const editor = { id: user.id, token: createToken(db, { userId: user.id, kind: "api" }, NOW).token };
  const family = makeFamily(db, user.id);
  const v = makeUser(db, { email: "viewer@test" });
  db.insert(familyMembers).values({ familyId: family.id, userId: v.id, role: "viewer", joinedAt: NOW }).run();
  const viewer = { id: v.id, token: createToken(db, { userId: v.id, kind: "api" }, NOW).token };
  const runner = new ChatRunner(env, options.maxConcurrent ?? 4, () => {});
  let ticking: ReturnType<typeof setInterval> | null = null;
  if (options.worker !== false) ticking = setInterval(() => runner.tick(), 5);
  const fire = async (method: string, path: string, body: unknown) => {
    const res = await handler(
      new Request(BASE + path, {
        method,
        headers: { "content-type": "application/json", authorization: `Bearer ${editor.token}` },
        body: JSON.stringify(body),
      }),
    );
    await res.body?.cancel();
    return res.status;
  };
  return {
    db,
    env,
    store,
    handler,
    as,
    call: as(editor.token),
    editor,
    familyId: family.id,
    view: as(viewer.token),
    viewer,
    ai: `/families/${family.id}/ai`,
    f: `/families/${family.id}`,
    fire,
    runner,
    stop: async () => {
      if (ticking) clearInterval(ticking);
      await runner.stop(2000);
    },
  };
}

/** Sets up the mock AI for the family. */
export async function configure(t: AssistantTest, settings: Record<string, unknown> = {}) {
  const res = await t.call("PUT", `${t.ai}/settings`, { baseUrl: AI, apiKey: KEY, model: "mock-large", ...settings });
  if (res.status !== 200) throw new Error(JSON.stringify(res.data));
  return res.data;
}
