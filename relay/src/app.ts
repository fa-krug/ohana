// The relay's HTTP API (Hono). Apps register their APNs token and get a sealed relay token;
// servers send opaque, end-to-end encrypted payloads to relay tokens. The relay builds the
// APNs request itself, so a server can't put text of its own on a lock screen: the visible
// text is the app's PUSH_FALLBACK string, shown only when the app's extension can't decrypt.
//
//   POST /v1/register  {apnsToken, environment, platform} → {relayToken}
//   POST /v1/send      {messages: [{relayToken, payload, collapseId?, ttl?}]} → {results}
//   GET  /health, GET /v1

import { getConnInfo } from "@hono/node-server/conninfo";
import { Hono, type Context } from "hono";
import { bodyLimit } from "hono/body-limit";
import { isIPv6 } from "node:net";
import { z } from "zod";
import pkg from "../package.json";
import type { ApnsClient, ApnsResponse } from "./apns";
import { DEFAULT_LIMITS, Limiter, type LimitsConfig } from "./limits";
import { Stats, type SendStatus } from "./stats";
import { APNS_TOKEN_RE, openToken, sealToken, type Secrets } from "./token";

export const MAX_BODY_BYTES = 64 * 1024;
export const MAX_MESSAGES = 100;
export const MAX_PAYLOAD_CHARS = 4000;
export const MAX_COLLAPSE_ID_BYTES = 64;
export const MAX_TTL = 86_400;
export const SEND_CONCURRENCY = 10;
export const DEFAULT_TOPIC = "de.fa-krug.Ohana";

export type AppOptions = {
  apns: ApnsClient;
  secrets: Secrets;
  /** apns-topic: the app's bundle id. */
  topic?: string;
  /** Milliseconds since the epoch (tests move it). */
  now?: () => number;
  limits?: Partial<LimitsConfig>;
  /** Take the client's IP from the last X-Forwarded-For entry (behind Traefik). */
  trustProxy?: boolean;
  stats?: Stats;
  log?: (message: string) => void;
};

export type SendResult = { status: SendStatus; retryAfter?: number };

const registerSchema = z.object({
  apnsToken: z.string(),
  environment: z.enum(["production", "sandbox"]),
  platform: z.enum(["ios", "macos"]),
});

// Only the shape: values out of range make that one message `invalid`, not the request a 400.
const sendSchema = z.object({
  messages: z
    .array(
      z.object({
        relayToken: z.string(),
        payload: z.string(),
        collapseId: z.string().nullish(),
        ttl: z.number().nullish(),
      }),
    )
    .min(1)
    .max(MAX_MESSAGES),
});

type Message = z.infer<typeof sendSchema>["messages"][number];

const BASE64_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
// Goes into an HTTP header: printable ASCII only.
const COLLAPSE_ID_RE = /^[\x20-\x7e]+$/;

export function createApp(options: AppOptions) {
  const { apns, secrets } = options;
  const topic = options.topic ?? DEFAULT_TOPIC;
  const now = options.now ?? Date.now;
  const stats = options.stats ?? new Stats();
  const log = options.log ?? ((message) => console.warn(message));
  const limits = { ...DEFAULT_LIMITS, ...options.limits };
  const registerLimit = new Limiter(limits.register);
  const sendIpLimit = new Limiter(limits.sendPerIp);
  const deviceLimit = new Limiter(limits.perDevice);

  const app = new Hono();

  app.use(
    "*",
    bodyLimit({
      maxSize: MAX_BODY_BYTES,
      onError: (c) => c.json({ error: "Body too large (at most 64 KB)" }, 413),
    }),
  );

  app.get("/health", (c) => c.json({ ok: true }));
  app.get("/v1", (c) => c.json({ name: "ohana-relay", version: pkg.version }));

  app.post("/v1/register", async (c) => {
    const limited = registerLimit.take(ipKey(clientIp(c, options.trustProxy)), now());
    if (!limited.ok) return tooMany(c, limited.retryAfter);

    const parsed = registerSchema.safeParse(await readJson(c));
    if (!parsed.success) {
      return c.json({ error: "Expected {apnsToken, environment: production | sandbox, platform: ios | macos}" }, 400);
    }
    const apnsToken = parsed.data.apnsToken.toLowerCase();
    if (!APNS_TOKEN_RE.test(apnsToken)) {
      return c.json({ error: "apnsToken must be 64 to 200 hex characters" }, 400);
    }
    stats.count("register");
    const relayToken = sealToken(secrets, {
      apnsToken,
      environment: parsed.data.environment,
      platform: parsed.data.platform,
      issuedAt: Math.floor(now() / 1000),
    });
    return c.json({ relayToken });
  });

  app.post("/v1/send", async (c) => {
    const parsed = sendSchema.safeParse(await readJson(c));
    // Every message counts against the caller's IP (a malformed request as one).
    const count = parsed.success ? parsed.data.messages.length : 1;
    const at = now();
    const limited = sendIpLimit.take(ipKey(clientIp(c, options.trustProxy)), at, count);
    if (!limited.ok) {
      stats.count("rejected", count);
      return tooMany(c, limited.retryAfter);
    }
    if (!parsed.success) {
      return c.json({ error: `Expected {messages: [{relayToken, payload, collapseId?, ttl?}]}, 1 to ${MAX_MESSAGES} messages` }, 400);
    }
    const { messages } = parsed.data;

    // Checks and limits run in order, before anything is sent, so a batch with the same
    // device twice counts it twice.
    const results: SendResult[] = new Array(messages.length);
    const jobs: (() => Promise<void>)[] = [];
    messages.forEach((message, i) => {
      const checked = check(message);
      if (!checked) {
        results[i] = { status: "invalid" };
        return;
      }
      const device = openToken(secrets, message.relayToken);
      if (!device) {
        results[i] = { status: "invalid" };
        return;
      }
      const taken = deviceLimit.take(device.apnsToken, at);
      if (!taken.ok) {
        results[i] = { status: "limited", retryAfter: taken.retryAfter };
        return;
      }
      const headers: Record<string, string> = {
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-topic": topic,
        "apns-expiration": String(checked.ttl === 0 ? 0 : Math.floor(at / 1000) + checked.ttl),
      };
      if (checked.collapseId) headers["apns-collapse-id"] = checked.collapseId;
      jobs.push(async () => {
        let res: ApnsResponse;
        try {
          res = await apns.send(device.environment, device.apnsToken, headers, apnsBody(message.payload));
        } catch (err) {
          log(`[apns] ${device.environment}: request failed: ${(err as Error)?.message ?? err}`);
          results[i] = { status: "error" };
          return;
        }
        results[i] = mapAnswer(res);
        if (results[i].status === "error") {
          log(`[apns] ${device.environment}: ${res.status}${res.reason ? ` ${res.reason}` : ""}`);
        }
      });
    });
    await runLimited(jobs, SEND_CONCURRENCY);
    for (const r of results) stats.count(r.status);
    return c.json({ results });
  });

  app.notFound((c) => c.json({ error: "Not found" }, 404));
  app.onError((err, c) => {
    log(`[http] ${c.req.method} ${c.req.path}: ${err.message}`);
    return c.json({ error: "Internal error" }, 500);
  });

  return app;
}

/** The APNs request body: fixed visible text, the server's ciphertext in "o". */
export function apnsBody(payload: string): string {
  return JSON.stringify({
    aps: { alert: { "loc-key": "PUSH_FALLBACK" }, "mutable-content": 1, sound: "default" },
    o: payload,
  });
}

/** APNs' answer → the status a server acts on. */
export function mapAnswer(res: ApnsResponse): SendResult {
  if (res.status === 200) return { status: "ok" };
  if (res.status === 410) return { status: "gone" };
  if (
    res.status === 400 &&
    (res.reason === "BadDeviceToken" || res.reason === "DeviceTokenNotForTopic" || res.reason === "Unregistered")
  ) {
    return { status: "gone" };
  }
  if (res.status === 429) return { status: "limited", retryAfter: 60 };
  return { status: "error" };
}

/** A message's values, or null when one is out of range. */
function check(message: Message): { ttl: number; collapseId?: string } | null {
  const { payload, collapseId } = message;
  if (payload.length === 0 || payload.length > MAX_PAYLOAD_CHARS || !BASE64_RE.test(payload)) return null;
  if (collapseId != null) {
    if (!COLLAPSE_ID_RE.test(collapseId) || Buffer.byteLength(collapseId) > MAX_COLLAPSE_ID_BYTES) return null;
  }
  const ttl = message.ttl ?? MAX_TTL;
  if (!Number.isInteger(ttl) || ttl < 0 || ttl > MAX_TTL) return null;
  return { ttl, collapseId: collapseId ?? undefined };
}

async function readJson(c: Context): Promise<unknown> {
  try {
    return JSON.parse(await c.req.text());
  } catch {
    return undefined;
  }
}

function tooMany(c: Context, retryAfter: number) {
  c.header("Retry-After", String(retryAfter));
  return c.json({ error: "Too many requests" }, 429);
}

/** The caller's address: behind a proxy the last X-Forwarded-For entry (the one it added). */
export function clientIp(c: Context, trustProxy = false): string {
  if (trustProxy) {
    const last = c.req.header("x-forwarded-for")?.split(",").pop()?.trim();
    if (last) return last;
  }
  try {
    return getConnInfo(c).remote.address ?? "unknown";
  } catch {
    return "unknown";
  }
}

/** The key limits count by: an IPv4 address, or an IPv6 address's /64 (one host's usual share). */
export function ipKey(ip: string): string {
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(ip);
  if (mapped) return mapped[1];
  if (!isIPv6(ip)) return ip;
  const [head, tail = ""] = ip.split("::");
  const front = head ? head.split(":") : [];
  const back = tail ? tail.split(":") : [];
  const groups = ip.includes("::")
    ? [...front, ...new Array(8 - front.length - back.length).fill("0"), ...back]
    : front;
  return `${groups
    .slice(0, 4)
    .map((g) => g.toLowerCase().replace(/^0+(?=.)/, ""))
    .join(":")}::/64`;
}

/** Runs the jobs with at most `limit` at a time. */
async function runLimited(jobs: (() => Promise<void>)[], limit: number): Promise<void> {
  let next = 0;
  const worker = async () => {
    while (next < jobs.length) await jobs[next++]();
  };
  await Promise.all(Array.from({ length: Math.min(limit, jobs.length) }, worker));
}
