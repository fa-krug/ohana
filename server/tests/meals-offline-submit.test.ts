import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { IDBFactory } from "fake-indexeddb";
import { count, all } from "@/lib/offline/queue";
import { submitChecked, submitUncheckAll } from "@/lib/offline/submit";

beforeEach(() => {
  globalThis.indexedDB = new IDBFactory();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("submitChecked", () => {
  it("returns synced with the server's checked value online", async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ checked: true }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const res = await submitChecked("f1", "i1", true);
    expect(res).toEqual({ result: "synced", checked: true });
    const [url, init] = (fetchMock.mock.calls as unknown as [string, RequestInit][])[0];
    expect(url).toBe("/api/v1/families/f1/shopping/toggle");
    expect(JSON.parse(init.body as string)).toEqual({ kind: "set", itemId: "i1", checked: true });
    expect(await count()).toBe(0);
  });

  it("returns error on a non-2xx response and does not enqueue", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("no", { status: 500 })));
    const res = await submitChecked("f1", "i1", true);
    expect(res.result).toBe("error");
    expect(await count()).toBe(0);
  });

  it("enqueues and returns queued when the network is unavailable", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("offline"); }));
    const res = await submitChecked("f1", "i1", true);
    expect(res.result).toBe("queued");
    const ops = await all();
    expect(ops).toHaveLength(1);
    expect(ops[0]).toMatchObject({ kind: "set", familyId: "f1", payload: { itemId: "i1", checked: true } });
  });
});

describe("submitUncheckAll", () => {
  it("enqueues an uncheck-all op when offline", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("offline"); }));
    const res = await submitUncheckAll("f1", ["i1", "i2"]);
    expect(res).toBe("queued");
    const ops = await all();
    expect(ops[0]).toMatchObject({ kind: "uncheck-all", familyId: "f1", payload: { itemIds: ["i1", "i2"] } });
  });
});
