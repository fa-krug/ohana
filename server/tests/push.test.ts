// Phase 9, push to the app through the relay: the sealed payload (a fixed vector the app's
// tests share), the device routes under /api/v1/me/push, delivery to the family's members'
// devices and the hooks in the notifications. The relay is a fake; nothing touches the network.

import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { handleAccountApp } from "@/lib/auth/app-routes";
import { createToken, deleteToken } from "@/lib/auth/tokens";
import type { Db } from "@/lib/db";
import * as schema from "@/lib/db/schema";
import { notifyRun } from "@/lib/appointments/notify";
import { notifyFamily } from "@/lib/notifications";
import { notifyEvent, setPref } from "@/lib/notifications/prefs";
import { DEFAULT_PUSH_RELAY_URL, pushRelayUrl, sameRelay } from "@/lib/push/config";
import { pushToFamily } from "@/lib/push/deliver";
import { registerDevice } from "@/lib/push/devices";
import { MAX_SEALED_BYTES, collapseIdFor, open, openPayload, pathOfUrl, sealPayload } from "@/lib/push/payload";
import type { RelayClient, RelayMessage, RelayResult } from "@/lib/push/relay";
import { serverInfo } from "@/lib/server-info";
import { makeResult, makeRun, makeSearch } from "@/lib/test/appointments";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const RELAY = DEFAULT_PUSH_RELAY_URL;
const keyOf = (n: number) => Buffer.alloc(32, n);

/** A fake relay: records what it got, answers `answer(message)` (default ok). */
function fakeRelay(answer: (m: RelayMessage) => RelayResult["status"] = () => "ok") {
  const calls: { url: string; messages: RelayMessage[] }[] = [];
  const relay: RelayClient = {
    async send(url, messages) {
      calls.push({ url, messages });
      return messages.map((m) => ({ status: answer(m) }));
    },
  };
  return { relay, calls, messages: () => calls.flatMap((c) => c.messages) };
}

afterEach(() => vi.unstubAllEnvs());

describe("payload", () => {
  it("matches the vector the app decrypts (CryptoKit's combined layout)", () => {
    const key = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
    const sealed =
      "oKGio6SlpqeoqaqrnToKD3/6Lp0WDPO/Ylj6/DjNNXz9lW5O/mFC/12RV0agtfs8MEdzzcANj+olWPOYM3NkckD/fFEnP2ZxxxHp1drY5B0SicaGlY+WdPaHqJj3Kc3FqOPkeQr+EU+om82TFfDqplQtSA==";
    expect(open(key, sealed).toString("utf8")).toBe(
      '{"v":1,"title":"Hallo","body":"Grüße 👋","path":"/f/fam/calendar","familyId":"fam"}',
    );
  });

  it("seals and opens, and shortens a long body to fit the relay", () => {
    const key = keyOf(7);
    const p = { v: 1 as const, title: "T", body: "x", path: "/f/a" };
    expect(openPayload(key, sealPayload(key, p))).toEqual(p);
    const long = { v: 1 as const, title: "Shopping", body: "ä😀\"\n".repeat(2000), familyId: "f" };
    const sealed = sealPayload(key, long);
    expect(Buffer.from(sealed, "base64").length).toBeLessThanOrEqual(MAX_SEALED_BYTES);
    expect(sealed.length).toBeLessThanOrEqual(4000);
    const back = openPayload(key, sealed);
    expect(back.title).toBe("Shopping");
    expect(back.body.endsWith("…")).toBe(true);
    expect(back.body.length).toBeGreaterThan(100);
  });

  it("makes collapse ids that depend on the device key", () => {
    const a = collapseIdFor(keyOf(1), "chat:1");
    expect(a).toMatch(/^[A-Za-z0-9_-]{22}$/);
    expect(collapseIdFor(keyOf(1), "chat:1")).toBe(a);
    expect(collapseIdFor(keyOf(2), "chat:1")).not.toBe(a);
    expect(a).not.toContain("chat");
  });

  it("takes the path of a link", () => {
    expect(pathOfUrl("https://ohana.test/f/x/meals?tab=1")).toBe("/f/x/meals?tab=1");
    expect(pathOfUrl("/f/x")).toBe("/f/x");
    expect(pathOfUrl("")).toBeUndefined();
  });
});

describe("config", () => {
  it("uses fa-krug's relay unless PUSH_RELAY_URL says otherwise", () => {
    expect(pushRelayUrl({})).toBe(RELAY);
    expect(pushRelayUrl({ PUSH_RELAY_URL: "" })).toBeNull();
    expect(pushRelayUrl({ PUSH_RELAY_URL: "https://push.example/" })).toBe("https://push.example");
    expect(pushRelayUrl({ PUSH_RELAY_URL: "nonsense" })).toBeNull();
    expect(serverInfo({ PUSH_RELAY_URL: "" }).push).toBeNull();
    expect(serverInfo({}).push).toEqual({ relay: RELAY });
    expect(sameRelay("https://OHANA-push.fa-krug.de/", RELAY)).toBe(true);
    expect(sameRelay("https://evil.example", RELAY)).toBe(false);
  });
});

type Res = { status: number; data: any };

describe("the device routes", () => {
  let db: Db;
  let userId: string;
  let device: { token: string; row: { id: string } };
  let relay: ReturnType<typeof fakeRelay>;
  const call = async (method: string, path: string, body?: unknown): Promise<Res> => {
    const res = await handleAccountApp(
      db,
      new Request(`http://ohana.test/api/v1/me/${path}`, {
        method,
        headers: { authorization: `Bearer ${device.token}`, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
        body: body !== undefined ? JSON.stringify(body) : undefined,
      }),
      path.split("/").filter(Boolean),
      NOW,
      { relay: relay.relay },
    );
    const text = await res.text();
    return { status: res.status, data: text ? JSON.parse(text) : null };
  };
  const registration = (over: Record<string, unknown> = {}) => ({
    relay: RELAY,
    relayToken: "r1.abc_DEF-123",
    key: keyOf(3).toString("base64"),
    platform: "ios",
    ...over,
  });

  beforeEach(() => {
    db = createTestDb();
    userId = makeUser(db).id;
    device = createToken(db, { userId, kind: "api", name: "iPhone (app)" }, NOW);
    relay = fakeRelay();
  });

  it("registers, mutes, tests and removes the calling device", async () => {
    expect((await call("GET", "push")).data).toMatchObject({ registered: false, mutedFamilyIds: [] });
    const put = await call("PUT", "push", registration({ mutedFamilyIds: ["f1", "f1"] }));
    expect(put.status).toBe(200);
    expect(put.data).toMatchObject({ registered: true, platform: "ios", mutedFamilyIds: ["f1"] });
    // Stored sealed.
    const row = db.select().from(schema.pushDevices).get()!;
    expect(row.tokenId).toBe(device.row.id);
    expect(row.relayToken).not.toContain("r1.");
    // Renewing keeps one row and the muted families unless given.
    expect((await call("PUT", "push", registration({ relayToken: "r1.new" }))).data.mutedFamilyIds).toEqual(["f1"]);
    expect(db.select().from(schema.pushDevices).all()).toHaveLength(1);
    expect((await call("PATCH", "push", { mutedFamilyIds: [] })).data.mutedFamilyIds).toEqual([]);

    const test = await call("POST", "push/test");
    expect(test.status).toBe(200);
    const [m] = relay.messages();
    expect(m.relayToken).toBe("r1.new");
    expect(openPayload(keyOf(3), m.payload)).toMatchObject({ v: 1, title: "Ohana test message" });

    expect((await call("DELETE", "push")).data.registered).toBe(false);
    expect(db.select().from(schema.pushDevices).all()).toHaveLength(0);
    expect((await call("POST", "push/test")).status).toBe(404);
  });

  it("refuses another relay, bad keys and tokens, and answers 404 when push is off", async () => {
    expect((await call("PUT", "push", registration({ relay: "https://evil.example" }))).status).toBe(409);
    expect((await call("PUT", "push", registration({ key: "c2hvcnQ=" }))).status).toBe(400);
    expect((await call("PUT", "push", registration({ relayToken: "apns-token" }))).status).toBe(400);
    expect((await call("PUT", "push", registration({ platform: "android" }))).status).toBe(400);
    expect((await call("PATCH", "push", { mutedFamilyIds: [] })).status).toBe(404);
    vi.stubEnv("PUSH_RELAY_URL", "");
    expect((await call("PUT", "push", registration())).status).toBe(404);
  });

  it("goes with the API token (sign out)", async () => {
    await call("PUT", "push", registration());
    deleteToken(db, device.row.id);
    expect(db.select().from(schema.pushDevices).all()).toHaveLength(0);
  });

  it("says when the test push fails", async () => {
    await call("PUT", "push", registration());
    relay = fakeRelay(() => "error");
    const res = await call("POST", "push/test");
    expect(res.status).toBe(502);
    relay = fakeRelay(() => "gone");
    expect((await call("POST", "push/test")).status).toBe(502);
    expect((await call("GET", "push")).data.registered).toBe(false);
  });
});

describe("delivery", () => {
  let db: Db;
  let familyId: string;
  let editorId: string;
  let viewerId: string;
  let outsiderId: string;

  /** A registered device for `userId`, with key byte `n` and relay token `r1.<n>`. */
  const addDevice = (userId: string, n: number, muted: string[] = []) => {
    const { row } = createToken(db, { userId, kind: "api", name: `Device ${n}` }, NOW);
    return registerDevice(
      db,
      { id: userId },
      row.id,
      { relay: RELAY, relayToken: `r1.${n}`, key: keyOf(n).toString("base64"), platform: "ios", mutedFamilyIds: muted },
      NOW,
    );
  };

  beforeEach(() => {
    db = createTestDb();
    editorId = makeUser(db).id;
    viewerId = makeUser(db).id;
    outsiderId = makeUser(db).id;
    familyId = makeFamily(db, editorId, [{ userId: viewerId, role: "viewer" }]).id;
  });

  it("reaches the members' unmuted devices, sealed for each", async () => {
    addDevice(editorId, 1);
    addDevice(viewerId, 2);
    addDevice(viewerId, 3, [familyId]);
    addDevice(outsiderId, 4);
    const relay = fakeRelay();
    const res = await pushToFamily(
      db,
      familyId,
      { title: "T", body: "B", url: `https://ohana.test/f/${familyId}/calendar`, collapseKey: "x", event: "coverage_gap" },
      { relay: relay.relay, now: NOW },
    );
    expect(res).toEqual({ sent: 2, failed: 0 });
    expect(relay.calls).toHaveLength(1);
    expect(relay.calls[0].url).toBe(RELAY);
    const byToken = Object.fromEntries(relay.messages().map((m) => [m.relayToken, m]));
    expect(Object.keys(byToken).sort()).toEqual(["r1.1", "r1.2"]);
    expect(openPayload(keyOf(2), byToken["r1.2"].payload)).toEqual({
      v: 1,
      title: "T",
      body: "B",
      path: `/f/${familyId}/calendar`,
      familyId,
      event: "coverage_gap",
    });
    expect(byToken["r1.1"].collapseId).toBe(collapseIdFor(keyOf(1), "x"));
    const sent = db.select().from(schema.pushDevices).where(eq(schema.pushDevices.userId, editorId)).get()!;
    expect(sent.lastSentAt).toEqual(NOW);
  });

  it("only some accounts' devices when asked", async () => {
    addDevice(editorId, 1);
    addDevice(viewerId, 2);
    const relay = fakeRelay();
    await pushToFamily(db, familyId, { title: "T", body: "B" }, { relay: relay.relay, userIds: [viewerId] });
    expect(relay.messages().map((m) => m.relayToken)).toEqual(["r1.2"]);
  });

  it("forgets gone devices and notes other failures", async () => {
    addDevice(editorId, 1);
    addDevice(viewerId, 2);
    const relay = fakeRelay((m) => (m.relayToken === "r1.1" ? "gone" : "limited"));
    expect(await pushToFamily(db, familyId, { title: "T", body: "B" }, { relay: relay.relay })).toEqual({ sent: 0, failed: 2 });
    const left = db.select().from(schema.pushDevices).all();
    expect(left.map((d) => d.userId)).toEqual([viewerId]);
    expect(left[0].lastError).toBe("limited");
  });

  it("sends nothing when push is off", async () => {
    addDevice(editorId, 1);
    const relay = fakeRelay();
    expect(await pushToFamily(db, familyId, { title: "T", body: "B" }, { relay: relay.relay, relayUrl: null })).toEqual({
      sent: 0,
      failed: 0,
    });
    expect(relay.calls).toHaveLength(0);
  });

  it("is part of notifyFamily only with `app`, and counts there", async () => {
    addDevice(editorId, 1);
    const relay = fakeRelay();
    const msg = { title: "T", body: "B", url: "https://ohana.test/f/x" };
    expect(await notifyFamily(db, familyId, msg, { push: relay.relay })).toEqual({ sent: 0, failed: 0 });
    expect(await notifyFamily(db, familyId, msg, { push: relay.relay, app: true })).toEqual({ sent: 1, failed: 0 });
  });

  it("follows the event's app switch and passes the event", async () => {
    addDevice(editorId, 1);
    addDevice(viewerId, 2);
    const relay = fakeRelay();
    const msg = { title: "T", body: "B", url: "https://ohana.test/f/x" };
    expect(await notifyEvent(db, familyId, "coverage_gap", msg, { push: relay.relay })).toEqual({ sent: 2, failed: 0 });
    expect(openPayload(keyOf(1), relay.messages()[0].payload).event).toBe("coverage_gap");
    // An older app's PUT (no `app`) keeps the switch as it is.
    setPref(db, { id: editorId }, familyId, { event: "coverage_gap", enabled: true, channelIds: null, app: false }, NOW);
    setPref(db, { id: editorId }, familyId, { event: "coverage_gap", enabled: true, channelIds: null }, NOW);
    relay.calls.length = 0;
    expect(await notifyEvent(db, familyId, "coverage_gap", msg, { push: relay.relay })).toEqual({ sent: 0, failed: 0 });
    expect(relay.calls).toHaveLength(0);
    // userIds narrows (the assistant's chat is one person's).
    expect(await notifyEvent(db, familyId, "shopping_reminder", msg, { push: relay.relay, userIds: [viewerId] })).toBeNull();
    setPref(db, { id: editorId }, familyId, { event: "assistant_turn_finished", enabled: true, channelIds: [] }, NOW);
    expect(
      await notifyEvent(db, familyId, "assistant_turn_finished", msg, { push: relay.relay, userIds: [viewerId] }),
    ).toEqual({ sent: 1, failed: 0 });
    expect(relay.messages().map((m) => m.relayToken)).toEqual(["r1.2"]);
  });

  it("notifies appointment finds to the app unless the search says not to", async () => {
    addDevice(editorId, 1);
    const relay = fakeRelay();
    const s = makeSearch(db, familyId, { name: "Derm" });
    const run = makeRun(db, s.id);
    makeResult(db, run.id, { doctorName: "Dr A" });
    // No channels at all: the app alone counts as told.
    expect(await notifyRun(db, run.id, { push: relay.relay, now: NOW })).toBe(true);
    const [m] = relay.messages();
    expect(openPayload(keyOf(1), m.payload)).toMatchObject({ event: "appointment_found", familyId });
    expect(m.collapseId).toBe(collapseIdFor(keyOf(1), `search:${s.id}`));

    db.update(schema.apptSearches).set({ notifyApp: false }).where(eq(schema.apptSearches.id, s.id)).run();
    const run2 = makeRun(db, s.id, { startedAt: new Date(NOW.getTime() - 60_000) });
    makeResult(db, run2.id, { doctorName: "Dr B" });
    relay.calls.length = 0;
    expect(await notifyRun(db, run2.id, { push: relay.relay, now: NOW })).toBe(false);
    expect(relay.calls).toHaveLength(0);
  });
});
