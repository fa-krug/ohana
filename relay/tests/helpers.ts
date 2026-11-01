// Shared test setup: random secrets, a fake APNs that records requests, an app on a movable clock.
import { randomBytes } from "node:crypto";
import type { ApnsClient, ApnsResponse } from "../src/apns";
import { createApp, type AppOptions } from "../src/app";
import type { Environment, Secrets } from "../src/token";

export function newSecrets(): Secrets {
  return { current: randomBytes(32) };
}

export type SentRequest = {
  environment: Environment;
  deviceToken: string;
  headers: Record<string, string>;
  body: string;
};

/** Records every request; answers with `answer` (200 by default). */
export class FakeApns implements ApnsClient {
  sent: SentRequest[] = [];
  answer: (req: SentRequest) => ApnsResponse | Promise<ApnsResponse> = () => ({ status: 200 });

  async send(environment: Environment, deviceToken: string, headers: Record<string, string>, body: string) {
    const req = { environment, deviceToken, headers, body };
    this.sent.push(req);
    return this.answer(req);
  }
}

export const TOKEN_A = "a".repeat(64);
export const TOKEN_B = "b".repeat(64);
export const NOW = Date.UTC(2026, 10, 1, 12, 0, 0);

export function setup(options: Partial<AppOptions> = {}) {
  const apns = new FakeApns();
  const secrets = options.secrets ?? newSecrets();
  const clock = { now: NOW };
  const logs: string[] = [];
  const app = createApp({
    apns,
    secrets,
    now: () => clock.now,
    trustProxy: true,
    log: (m) => logs.push(m),
    ...options,
  });
  const post = (path: string, body: unknown, ip = "203.0.113.7") =>
    app.request(path, {
      method: "POST",
      headers: { "content-type": "application/json", "x-forwarded-for": `10.0.0.1, ${ip}` },
      body: typeof body === "string" ? body : JSON.stringify(body),
    });
  const register = async (apnsToken = TOKEN_A, environment = "production", platform = "ios", ip?: string) => {
    const res = await post("/v1/register", { apnsToken, environment, platform }, ip);
    if (res.status !== 200) throw new Error(`register: ${res.status}`);
    return ((await res.json()) as { relayToken: string }).relayToken;
  };
  const send = async (messages: unknown[], ip?: string) => {
    const res = await post("/v1/send", { messages }, ip);
    return { res, json: (await res.json()) as any };
  };
  return { app, apns, secrets, clock, logs, post, register, send };
}
