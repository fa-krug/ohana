import { apnsBody } from "../src/app";
import { sealToken, openToken } from "../src/token";
import { NOW, TOKEN_A, TOKEN_B, setup } from "./helpers";

const PAYLOAD = Buffer.from("ciphertext").toString("base64");

describe("GET /health and /v1", () => {
  it("answer", async () => {
    const { app } = setup();
    expect(await (await app.request("/health")).json()).toEqual({ ok: true });
    expect(await (await app.request("/v1")).json()).toEqual({ name: "ohana-relay", version: "0.1.0" });
    const missing = await app.request("/nope");
    expect(missing.status).toBe(404);
    expect(await missing.json()).toEqual({ error: "Not found" });
  });
});

describe("POST /v1/register", () => {
  it("seals the lowercased token, environment, platform and time", async () => {
    const { post, secrets } = setup();
    const res = await post("/v1/register", { apnsToken: "ABCDEF".repeat(11), environment: "sandbox", platform: "macos" });
    expect(res.status).toBe(200);
    const { relayToken } = (await res.json()) as { relayToken: string };
    expect(relayToken).toMatch(/^r1\.[A-Za-z0-9_-]+$/);
    expect(openToken(secrets, relayToken)).toEqual({
      apnsToken: "abcdef".repeat(11),
      environment: "sandbox",
      platform: "macos",
      issuedAt: NOW / 1000,
    });
  });

  it("refuses bad input with 400", async () => {
    const { post } = setup();
    const bad: unknown[] = [
      "not json",
      {},
      { apnsToken: "a".repeat(63), environment: "production", platform: "ios" },
      { apnsToken: "a".repeat(201), environment: "production", platform: "ios" },
      { apnsToken: "g".repeat(64), environment: "production", platform: "ios" },
      { apnsToken: 12, environment: "production", platform: "ios" },
      { apnsToken: TOKEN_A, environment: "development", platform: "ios" },
      { apnsToken: TOKEN_A, environment: "production", platform: "watchos" },
      { apnsToken: TOKEN_A, environment: "production" },
    ];
    for (const body of bad) {
      const res = await post("/v1/register", body);
      expect(res.status, JSON.stringify(body)).toBe(400);
      expect(await res.json()).toHaveProperty("error");
    }
    expect((await post("/v1/register", { apnsToken: "f".repeat(200), environment: "production", platform: "ios" })).status).toBe(200);
  });

  it("allows 30 a minute per IP (429 with Retry-After)", async () => {
    const { post, clock } = setup();
    const body = { apnsToken: TOKEN_A, environment: "production", platform: "ios" };
    for (let i = 0; i < 30; i++) expect((await post("/v1/register", body)).status).toBe(200);
    const res = await post("/v1/register", body);
    expect(res.status).toBe(429);
    expect(res.headers.get("retry-after")).toBe("60");
    expect((await post("/v1/register", body, "198.51.100.1")).status).toBe(200);
    clock.now += 60_000;
    expect((await post("/v1/register", body)).status).toBe(200);
  });

  it("counts an IPv6 /64 as one caller", async () => {
    const { post } = setup();
    const body = { apnsToken: TOKEN_A, environment: "production", platform: "ios" };
    for (let i = 0; i < 30; i++) expect((await post("/v1/register", body, `2001:db8:1:2::${i.toString(16)}`)).status).toBe(200);
    expect((await post("/v1/register", body, "2001:db8:1:2:ffff::1")).status).toBe(429);
    expect((await post("/v1/register", body, "2001:db8:1:3::1")).status).toBe(200);
  });
});

describe("POST /v1/send", () => {
  it("builds the APNs request itself", async () => {
    const { register, send, apns } = setup();
    const relayToken = await register(TOKEN_A, "sandbox");
    const { res, json } = await send([{ relayToken, payload: PAYLOAD, collapseId: "abc-DEF_123", ttl: 3600 }]);
    expect(res.status).toBe(200);
    expect(json).toEqual({ results: [{ status: "ok" }] });
    expect(apns.sent).toHaveLength(1);
    const [req] = apns.sent;
    expect(req.environment).toBe("sandbox");
    expect(req.deviceToken).toBe(TOKEN_A);
    expect(req.headers).toEqual({
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-topic": "de.fa-krug.Ohana",
      "apns-expiration": String(NOW / 1000 + 3600),
      "apns-collapse-id": "abc-DEF_123",
    });
    expect(req.body).toBe(
      `{"aps":{"alert":{"loc-key":"PUSH_FALLBACK"},"mutable-content":1,"sound":"default"},"o":"${PAYLOAD}"}`,
    );
  });

  it("defaults ttl to a day, 0 means expiration 0, no collapse id without one, topic from options", async () => {
    const { register, send, apns } = setup({ topic: "com.example.Fork" });
    const relayToken = await register();
    await send([{ relayToken, payload: PAYLOAD }, { relayToken, payload: PAYLOAD, ttl: 0, collapseId: null }]);
    expect(apns.sent[0].environment).toBe("production");
    expect(apns.sent[0].headers["apns-expiration"]).toBe(String(NOW / 1000 + 86_400));
    expect(apns.sent[0].headers["apns-topic"]).toBe("com.example.Fork");
    expect(apns.sent[0].headers).not.toHaveProperty("apns-collapse-id");
    expect(apns.sent[1].headers["apns-expiration"]).toBe("0");
  });

  it("maps every APNs answer", async () => {
    const { register, send, apns, logs } = setup();
    const relayToken = await register();
    const answers = [
      { status: 200 },
      { status: 410, reason: "Unregistered" },
      { status: 400, reason: "BadDeviceToken" },
      { status: 400, reason: "DeviceTokenNotForTopic" },
      { status: 400, reason: "Unregistered" },
      { status: 400, reason: "BadCollapseId" },
      { status: 403, reason: "InvalidProviderToken" },
      { status: 403, reason: "ExpiredProviderToken" },
      { status: 429, reason: "TooManyRequests" },
      { status: 500, reason: "InternalServerError" },
      { status: 503, reason: "ServiceUnavailable" },
    ];
    let i = 0;
    apns.answer = () => answers[i++];
    const { json } = await send(answers.map(() => ({ relayToken, payload: PAYLOAD })));
    // Sent in order with a fake that answers at once, so answer i belongs to message i.
    expect(json.results).toEqual([
      { status: "ok" },
      { status: "gone" },
      { status: "gone" },
      { status: "gone" },
      { status: "gone" },
      { status: "error" },
      { status: "error" },
      { status: "error" },
      { status: "limited", retryAfter: 60 },
      { status: "error" },
      { status: "error" },
    ]);
    expect(logs).toEqual([
      "[apns] production: 400 BadCollapseId",
      "[apns] production: 403 InvalidProviderToken",
      "[apns] production: 403 ExpiredProviderToken",
      "[apns] production: 500 InternalServerError",
      "[apns] production: 503 ServiceUnavailable",
    ]);
  });

  it("answers error when the APNs request fails, and logs neither token nor payload", async () => {
    const { register, send, apns, logs } = setup();
    const relayToken = await register();
    apns.answer = () => Promise.reject(new Error("no answer within 10000 ms"));
    const { json } = await send([{ relayToken, payload: PAYLOAD }]);
    expect(json.results).toEqual([{ status: "error" }]);
    expect(logs).toEqual(["[apns] production: request failed: no answer within 10000 ms"]);
    expect(logs.join()).not.toContain(TOKEN_A);
    expect(logs.join()).not.toContain(PAYLOAD);
  });

  it("marks only the bad messages invalid", async () => {
    const { register, send, apns } = setup();
    const relayToken = await register();
    const other = sealToken({ current: Buffer.alloc(32, 7) }, {
      apnsToken: TOKEN_B,
      environment: "production",
      platform: "ios",
      issuedAt: 1,
    });
    const tampered = relayToken.slice(0, -2) + (relayToken.endsWith("A") ? "BB" : "AA");
    const messages = [
      { relayToken, payload: PAYLOAD },
      { relayToken: other, payload: PAYLOAD },
      { relayToken: tampered, payload: PAYLOAD },
      { relayToken: "garbage", payload: PAYLOAD },
      { relayToken, payload: "not base64!" },
      { relayToken, payload: "abc" },
      { relayToken, payload: "" },
      { relayToken, payload: "A".repeat(4004) },
      { relayToken, payload: PAYLOAD, collapseId: "x".repeat(65) },
      { relayToken, payload: PAYLOAD, collapseId: "ü".repeat(20) },
      { relayToken, payload: PAYLOAD, collapseId: "" },
      { relayToken, payload: PAYLOAD, ttl: -1 },
      { relayToken, payload: PAYLOAD, ttl: 86_401 },
      { relayToken, payload: PAYLOAD, ttl: 1.5 },
      { relayToken, payload: "A".repeat(4000), collapseId: "x".repeat(64), ttl: 86_400 },
    ];
    const { res, json } = await send(messages);
    expect(res.status).toBe(200);
    expect(json.results.map((r: { status: string }) => r.status)).toEqual([
      "ok",
      ...Array(13).fill("invalid"),
      "ok",
    ]);
    expect(apns.sent).toHaveLength(2);
  });

  it("keeps the largest payload within APNs' 4 KB", () => {
    expect(Buffer.byteLength(apnsBody("A".repeat(4000)))).toBeLessThanOrEqual(4096);
  });

  it("refuses a malformed body with 400", async () => {
    const { post, register } = setup();
    const relayToken = await register();
    const message = { relayToken, payload: PAYLOAD };
    const bad: unknown[] = [
      "not json",
      {},
      { messages: [] },
      { messages: "x" },
      { messages: [{ payload: PAYLOAD }] },
      { messages: [{ relayToken, payload: 5 }] },
      { messages: [{ ...message, ttl: "60" }] },
      { messages: Array(101).fill(message) },
    ];
    for (const body of bad) {
      const res = await post("/v1/send", body);
      expect(res.status, JSON.stringify(body).slice(0, 80)).toBe(400);
      expect(await res.json()).toHaveProperty("error");
    }
    expect((await post("/v1/send", { messages: Array(100).fill(message) })).status).toBe(200);
  });

  it("refuses bodies over 64 KB with 413", async () => {
    const { post } = setup();
    const res = await post("/v1/send", { messages: [{ relayToken: "r1.x", payload: "A".repeat(70_000) }] });
    expect(res.status).toBe(413);
    expect(await res.json()).toHaveProperty("error");
  });

  it("limits a device to 30 a minute, keyed on the APNs token (registering again doesn't reset it)", async () => {
    const { register, send, clock, apns } = setup();
    const first = await register(TOKEN_A);
    const { json } = await send(Array(30).fill({ relayToken: first, payload: PAYLOAD }));
    expect(json.results.every((r: { status: string }) => r.status === "ok")).toBe(true);

    clock.now += 20_000;
    const again = await register(TOKEN_A, "sandbox", "macos");
    const other = await register(TOKEN_B);
    const next = await send([
      { relayToken: again, payload: PAYLOAD },
      { relayToken: other, payload: PAYLOAD },
    ]);
    expect(next.json.results).toEqual([{ status: "limited", retryAfter: 40 }, { status: "ok" }]);
    expect(apns.sent).toHaveLength(31);

    clock.now += 40_000;
    expect((await send([{ relayToken: again, payload: PAYLOAD }])).json.results).toEqual([{ status: "ok" }]);
  });

  it("limits a device to 500 a day", async () => {
    const { register, send, clock } = setup();
    const relayToken = await register();
    for (let minute = 0; minute < 17; minute++) {
      const n = minute < 16 ? 30 : 20; // 16 × 30 + 20 = 500
      const { json } = await send(Array(n).fill({ relayToken, payload: PAYLOAD }));
      expect(json.results.every((r: { status: string }) => r.status === "ok")).toBe(true);
      clock.now += 60_000;
    }
    const { json } = await send([{ relayToken, payload: PAYLOAD }]);
    expect(json.results).toEqual([{ status: "limited", retryAfter: 86_400 - 17 * 60 }]);
  });

  it("limits a source IP to 1000 messages a minute (the whole request 429)", async () => {
    const { send, clock, apns } = setup();
    // Invalid messages count too, and need no APNs requests.
    const message = { relayToken: "r1.AAAA", payload: PAYLOAD };
    for (let i = 0; i < 10; i++) expect((await send(Array(100).fill(message))).res.status).toBe(200);
    const { res } = await send([message]);
    expect(res.status).toBe(429);
    expect(res.headers.get("retry-after")).toBe("60");
    expect((await send([message], "198.51.100.9")).res.status).toBe(200);
    clock.now += 60_000;
    expect((await send([message])).res.status).toBe(200);
    expect(apns.sent).toHaveLength(0);
  });

  it("sends at most 10 at a time, and answers in the request's order", async () => {
    const { register, send, apns } = setup();
    const tokens = await Promise.all(
      Array.from({ length: 25 }, (_, i) => register(i.toString(16).padStart(2, "0").repeat(32))),
    );
    let running = 0;
    let most = 0;
    apns.answer = async (req) => {
      running++;
      most = Math.max(most, running);
      await new Promise((r) => setTimeout(r, 1 + (req.deviceToken.charCodeAt(1) % 5)));
      running--;
      // Odd devices are gone, so the order of results can be checked.
      return { status: parseInt(req.deviceToken.slice(0, 2), 16) % 2 ? 410 : 200 };
    };
    const { json } = await send(tokens.map((relayToken) => ({ relayToken, payload: PAYLOAD })));
    expect(most).toBe(10);
    expect(json.results.map((r: { status: string }) => r.status)).toEqual(
      tokens.map((_, i) => (i % 2 ? "gone" : "ok")),
    );
  });

  it("uses the socket address unless TRUST_PROXY", async () => {
    const { app } = setup({ trustProxy: false, limits: { register: [{ max: 1, windowMs: 60_000 }] } });
    const req = (ip: string) =>
      app.request("/v1/register", {
        method: "POST",
        headers: { "x-forwarded-for": ip },
        body: JSON.stringify({ apnsToken: TOKEN_A, environment: "production", platform: "ios" }),
      });
    // Without a socket (app.request) every caller is "unknown": X-Forwarded-For is ignored.
    expect((await req("1.1.1.1")).status).toBe(200);
    expect((await req("2.2.2.2")).status).toBe(429);
  });
});
