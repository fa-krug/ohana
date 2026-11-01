// The HTTP/2 client against a local cleartext HTTP/2 server standing in for APNs.
import { generateKeyPairSync, verify } from "node:crypto";
import http2 from "node:http2";
import type { AddressInfo } from "node:net";
import { Http2ApnsClient, makeJwt } from "../src/apns";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });

function decodeJwt(jwt: string) {
  const [header, claims, signature] = jwt.split(".");
  return {
    header: JSON.parse(Buffer.from(header, "base64url").toString()),
    claims: JSON.parse(Buffer.from(claims, "base64url").toString()),
    signature: Buffer.from(signature, "base64url"),
    input: `${header}.${claims}`,
  };
}

describe("makeJwt", () => {
  it("is an ES256 JWT with kid, iss and iat, signed with the key", () => {
    const jwt = makeJwt(privateKey, "ABC123DEFG", "HS26J3YA63", 1_790_000_000);
    const { header, claims, signature, input } = decodeJwt(jwt);
    expect(header).toEqual({ alg: "ES256", kid: "ABC123DEFG" });
    expect(claims).toEqual({ iss: "HS26J3YA63", iat: 1_790_000_000 });
    // JWS ES256 wants r ‖ s (64 bytes), not DER.
    expect(signature.length).toBe(64);
    expect(verify("sha256", Buffer.from(input), { key: publicKey, dsaEncoding: "ieee-p1363" }, signature)).toBe(true);
    const other = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).publicKey;
    expect(verify("sha256", Buffer.from(input), { key: other, dsaEncoding: "ieee-p1363" }, signature)).toBe(false);
  });
});

type Seen = { headers: http2.IncomingHttpHeaders; body: string };
type Handler = (stream: http2.ServerHttp2Stream, seen: Seen) => void;

async function fakeApns() {
  const seen: Seen[] = [];
  let sessions = 0;
  let handler: Handler = (stream) => {
    stream.respond({ ":status": 200 });
    stream.end();
  };
  const server = http2.createServer();
  server.on("session", () => sessions++);
  server.on("stream", (stream, headers) => {
    const chunks: Buffer[] = [];
    stream.on("data", (c: Buffer) => chunks.push(c));
    stream.on("end", () => {
      const s = { headers, body: Buffer.concat(chunks).toString() };
      seen.push(s);
      handler(stream, s);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return {
    seen,
    origin,
    sessions: () => sessions,
    server,
    answer(h: Handler) {
      handler = h;
    },
    reply(stream: http2.ServerHttp2Stream, status: number, reason?: string) {
      stream.respond({ ":status": status, "content-type": "application/json" });
      stream.end(reason ? JSON.stringify({ reason }) : undefined);
    },
    close: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
}

describe("Http2ApnsClient", () => {
  let apns: Awaited<ReturnType<typeof fakeApns>>;
  let sandbox: Awaited<ReturnType<typeof fakeApns>>;
  let client: Http2ApnsClient;
  let clock: number;
  const logs: string[] = [];

  beforeEach(async () => {
    apns = await fakeApns();
    sandbox = await fakeApns();
    clock = Date.UTC(2026, 10, 1);
    logs.length = 0;
    client = new Http2ApnsClient({
      key: privateKey,
      keyId: "ABC123DEFG",
      teamId: "HS26J3YA63",
      hosts: { production: apns.origin, sandbox: sandbox.origin },
      timeoutMs: 300,
      now: () => clock,
      log: (m) => logs.push(m),
    });
  });

  afterEach(async () => {
    client.close();
    for (const s of [apns, sandbox]) {
      // Open sessions keep close() waiting: don't wait long.
      await Promise.race([s.close(), new Promise((r) => setTimeout(r, 100))]);
    }
  });

  const headers = { "apns-push-type": "alert", "apns-priority": "10", "apns-topic": "de.fa-krug.Ohana", "apns-expiration": "0" };

  it("POSTs /3/device/<token> with the headers, a bearer JWT and the body", async () => {
    const res = await client.send("production", "ab".repeat(32), headers, '{"o":"x"}');
    expect(res).toEqual({ status: 200, reason: undefined });
    expect(apns.seen).toHaveLength(1);
    const [{ headers: h, body }] = apns.seen;
    expect(h[":method"]).toBe("POST");
    expect(h[":path"]).toBe(`/3/device/${"ab".repeat(32)}`);
    expect(h["apns-push-type"]).toBe("alert");
    expect(h["apns-priority"]).toBe("10");
    expect(h["apns-topic"]).toBe("de.fa-krug.Ohana");
    expect(h["apns-expiration"]).toBe("0");
    expect(body).toBe('{"o":"x"}');
    const auth = String(h.authorization);
    expect(auth).toMatch(/^bearer /);
    const { header, claims } = decodeJwt(auth.slice(7));
    expect(header).toEqual({ alg: "ES256", kid: "ABC123DEFG" });
    expect(claims).toEqual({ iss: "HS26J3YA63", iat: clock / 1000 });
    expect(sandbox.seen).toHaveLength(0);
  });

  it("picks the host by environment and keeps one session per host", async () => {
    await client.send("sandbox", "aa".repeat(32), headers, "{}");
    await client.send("sandbox", "aa".repeat(32), headers, "{}");
    await client.send("production", "aa".repeat(32), headers, "{}");
    expect(sandbox.seen).toHaveLength(2);
    expect(apns.seen).toHaveLength(1);
    expect(sandbox.sessions()).toBe(1);
  });

  it("returns APNs' status and reason", async () => {
    apns.answer((stream) => apns.reply(stream, 400, "BadDeviceToken"));
    expect(await client.send("production", "aa".repeat(32), headers, "{}")).toEqual({ status: 400, reason: "BadDeviceToken" });
    apns.answer((stream) => apns.reply(stream, 410, "Unregistered"));
    expect(await client.send("production", "aa".repeat(32), headers, "{}")).toEqual({ status: 410, reason: "Unregistered" });
  });

  it("reuses the JWT for 50 minutes, then makes a new one", async () => {
    const jwtOf = (i: number) => String(apns.seen[i].headers.authorization);
    await client.send("production", "aa".repeat(32), headers, "{}");
    clock += 49 * 60_000;
    await client.send("production", "aa".repeat(32), headers, "{}");
    clock += 60_000;
    await client.send("production", "aa".repeat(32), headers, "{}");
    expect(jwtOf(1)).toBe(jwtOf(0));
    expect(jwtOf(2)).not.toBe(jwtOf(1));
    expect(decodeJwt(jwtOf(2).slice(7)).claims.iat).toBe(clock / 1000);
  });

  it("makes a new JWT after ExpiredProviderToken and tries once more", async () => {
    await client.send("production", "aa".repeat(32), headers, "{}");
    clock += 1000; // a new JWT gets another iat
    let first = true;
    apns.answer((stream) => {
      if (first) {
        first = false;
        apns.reply(stream, 403, "ExpiredProviderToken");
      } else apns.reply(stream, 200);
    });
    expect((await client.send("production", "aa".repeat(32), headers, "{}")).status).toBe(200);
    expect(apns.seen).toHaveLength(3);
    expect(apns.seen[1].headers.authorization).toBe(apns.seen[0].headers.authorization);
    expect(apns.seen[2].headers.authorization).not.toBe(apns.seen[1].headers.authorization);

    // Expired again: the second answer stands.
    apns.answer((stream) => apns.reply(stream, 403, "ExpiredProviderToken"));
    expect(await client.send("production", "aa".repeat(32), headers, "{}")).toEqual({ status: 403, reason: "ExpiredProviderToken" });
  });

  it("times out", async () => {
    apns.answer(() => {
      // never answers
    });
    await expect(client.send("production", "aa".repeat(32), headers, "{}")).rejects.toThrow(/no answer within 300 ms/);
  });

  it("opens a new session after GOAWAY or a closed connection", async () => {
    await client.send("production", "aa".repeat(32), headers, "{}");
    expect(apns.sessions()).toBe(1);
    apns.answer((stream) => {
      apns.reply(stream, 200);
      stream.session?.goaway();
    });
    await client.send("production", "aa".repeat(32), headers, "{}");
    await new Promise((r) => setTimeout(r, 50));
    apns.answer((stream) => apns.reply(stream, 200));
    await client.send("production", "aa".repeat(32), headers, "{}");
    expect(apns.sessions()).toBe(2);

    apns.answer((stream) => {
      const session = stream.session;
      apns.reply(stream, 200);
      setImmediate(() => session?.destroy());
    });
    await client.send("production", "aa".repeat(32), headers, "{}");
    await new Promise((r) => setTimeout(r, 50));
    apns.answer((stream) => apns.reply(stream, 200));
    expect((await client.send("production", "aa".repeat(32), headers, "{}")).status).toBe(200);
    expect(apns.sessions()).toBe(3);
  });

  it("fails (doesn't hang) when the host can't be reached", async () => {
    const down = new Http2ApnsClient({
      key: privateKey,
      keyId: "ABC123DEFG",
      teamId: "HS26J3YA63",
      hosts: { production: "http://127.0.0.1:1", sandbox: "http://127.0.0.1:1" },
      timeoutMs: 2000,
      log: (m) => logs.push(m),
    });
    await expect(down.send("production", "aa".repeat(32), headers, "{}")).rejects.toThrow();
    expect(logs.some((l) => l.startsWith("[apns] production connection error"))).toBe(true);
    down.close();
  });
});
