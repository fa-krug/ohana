import { beforeEach, describe, expect, it, vi } from "vitest";
import { IDBFactory } from "fake-indexeddb";
import { enqueue, all } from "@/lib/offline/queue";
import { drainQueue } from "@/lib/offline/sync";

beforeEach(() => {
  globalThis.indexedDB = new IDBFactory();
});

function okFetch() {
  return vi.fn(async () => new Response(JSON.stringify({ checked: true }), { status: 200 }));
}

describe("drainQueue", () => {
  it("replays all ops and empties the queue on success", async () => {
    await enqueue({ familyId: "f1", kind: "toggle", payload: { itemId: "a" } });
    await enqueue({ familyId: "f1", kind: "toggle", payload: { itemId: "b" } });
    const fetchImpl = okFetch();
    const res = await drainQueue(fetchImpl as unknown as typeof fetch);
    expect(res).toEqual({ drained: 2, remaining: 0 });
    expect(await all()).toHaveLength(0);
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("sends kind + payload as the request body", async () => {
    await enqueue({ familyId: "f1", kind: "uncheck-all", payload: { itemIds: ["a", "b"] } });
    const fetchImpl = okFetch();
    await drainQueue(fetchImpl as unknown as typeof fetch);
    const calls = fetchImpl.mock.calls as Array<unknown[]>;
    const init = calls[0]?.[1] as RequestInit;
    expect(JSON.parse(init.body as string)).toEqual({ kind: "uncheck-all", itemIds: ["a", "b"] });
  });

  it("stops at the first network failure and keeps the remainder", async () => {
    await enqueue({ familyId: "f1", kind: "toggle", payload: { itemId: "a" } });
    await enqueue({ familyId: "f1", kind: "toggle", payload: { itemId: "b" } });
    let calls = 0;
    const fetchImpl = vi.fn(async () => {
      calls += 1;
      if (calls === 2) throw new Error("offline");
      return new Response("{}", { status: 200 });
    });
    const res = await drainQueue(fetchImpl as unknown as typeof fetch);
    expect(res).toEqual({ drained: 1, remaining: 1 });
    expect(await all()).toHaveLength(1);
  });

  it("stops on a non-2xx response", async () => {
    await enqueue({ familyId: "f1", kind: "toggle", payload: { itemId: "a" } });
    const fetchImpl = vi.fn(async () => new Response("nope", { status: 500 }));
    const res = await drainQueue(fetchImpl as unknown as typeof fetch);
    expect(res).toEqual({ drained: 0, remaining: 1 });
    expect(await all()).toHaveLength(1);
  });

  it("replays each op to its own family's route", async () => {
    await enqueue({ familyId: "f1", kind: "toggle", payload: { itemId: "a" } });
    await enqueue({ familyId: "f2", kind: "toggle", payload: { itemId: "b" } });
    const fetchImpl = okFetch();
    await drainQueue(fetchImpl as unknown as typeof fetch);
    const urls = (fetchImpl.mock.calls as Array<unknown[]>).map((c) => c[0]);
    expect(urls).toEqual(["/api/v1/families/f1/shopping/toggle", "/api/v1/families/f2/shopping/toggle"]);
  });

  it("drops an op the server rejects for good (4xx) and goes on", async () => {
    await enqueue({ familyId: "f1", kind: "toggle", payload: { itemId: "gone" } });
    await enqueue({ familyId: "f1", kind: "toggle", payload: { itemId: "b" } });
    let calls = 0;
    const fetchImpl = vi.fn(async () => {
      calls += 1;
      return calls === 1 ? new Response("{}", { status: 404 }) : new Response("{}", { status: 200 });
    });
    const res = await drainQueue(fetchImpl as unknown as typeof fetch);
    expect(res).toEqual({ drained: 2, remaining: 0 });
    expect(await all()).toHaveLength(0);
  });

  it("keeps ops while signed out (401)", async () => {
    await enqueue({ familyId: "f1", kind: "toggle", payload: { itemId: "a" } });
    const fetchImpl = vi.fn(async () => new Response("{}", { status: 401 }));
    const res = await drainQueue(fetchImpl as unknown as typeof fetch);
    expect(res).toEqual({ drained: 0, remaining: 1 });
  });

  it("no-ops on an empty queue", async () => {
    const fetchImpl = okFetch();
    const res = await drainQueue(fetchImpl as unknown as typeof fetch);
    expect(res).toEqual({ drained: 0, remaining: 0 });
    expect(fetchImpl).not.toHaveBeenCalled();
  });
});
