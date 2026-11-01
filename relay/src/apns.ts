// The APNs client: HTTP/2 to api.push.apple.com (production) or api.sandbox.push.apple.com
// (sandbox), token-based auth. One long-lived session per host (Apple asks for kept-open
// connections), opened again after it closes, gets a GOAWAY or fails. The provider token
// (an ES256 JWT) is reused for 50 minutes and made again early when APNs answers
// ExpiredProviderToken. Nothing here logs device tokens or payloads.

import { sign, type KeyObject } from "node:crypto";
import http2 from "node:http2";
import type { Environment } from "./token";

export type ApnsResponse = { status: number; reason?: string };

/** What the app needs from APNs (tests pass a fake). May throw (network, timeout). */
export interface ApnsClient {
  send(
    environment: Environment,
    deviceToken: string,
    headers: Record<string, string>,
    body: string,
  ): Promise<ApnsResponse>;
  close?(): void;
}

export const APNS_HOSTS: Record<Environment, string> = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
};

const JWT_LIFETIME_MS = 50 * 60 * 1000;

/** An APNs provider token: ES256 JWT with {alg, kid} and {iss, iat}. */
export function makeJwt(key: KeyObject, keyId: string, teamId: string, iat: number): string {
  const part = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const input = `${part({ alg: "ES256", kid: keyId })}.${part({ iss: teamId, iat })}`;
  const signature = sign("sha256", Buffer.from(input), { key, dsaEncoding: "ieee-p1363" });
  return `${input}.${signature.toString("base64url")}`;
}

type Jwt = { value: string; madeAt: number };

export type Http2ApnsOptions = {
  key: KeyObject;
  keyId: string;
  teamId: string;
  /** For tests: other origins than Apple's. */
  hosts?: Record<Environment, string>;
  timeoutMs?: number;
  now?: () => number;
  log?: (message: string) => void;
};

export class Http2ApnsClient implements ApnsClient {
  private readonly hosts: Record<Environment, string>;
  private readonly timeoutMs: number;
  private readonly now: () => number;
  private readonly log: (message: string) => void;
  private readonly sessions = new Map<Environment, http2.ClientHttp2Session>();
  private jwt: Jwt | null = null;

  constructor(private readonly options: Http2ApnsOptions) {
    this.hosts = options.hosts ?? APNS_HOSTS;
    this.timeoutMs = options.timeoutMs ?? 10_000;
    this.now = options.now ?? Date.now;
    this.log = options.log ?? ((message) => console.warn(message));
  }

  async send(
    environment: Environment,
    deviceToken: string,
    headers: Record<string, string>,
    body: string,
  ): Promise<ApnsResponse> {
    const jwt = this.currentJwt();
    const res = await this.request(environment, deviceToken, headers, body, jwt.value);
    if (res.status !== 403 || res.reason !== "ExpiredProviderToken") return res;
    // APNs thinks the token is too old (e.g. after a clock jump): make a new one (once, even
    // when several requests got this answer for the same token) and try again.
    if (this.jwt === jwt) this.jwt = null;
    return this.request(environment, deviceToken, headers, body, this.currentJwt().value);
  }

  close(): void {
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
  }

  private currentJwt(): Jwt {
    const now = this.now();
    if (!this.jwt || now - this.jwt.madeAt >= JWT_LIFETIME_MS) {
      const { key, keyId, teamId } = this.options;
      this.jwt = { value: makeJwt(key, keyId, teamId, Math.floor(now / 1000)), madeAt: now };
    }
    return this.jwt;
  }

  private session(environment: Environment): http2.ClientHttp2Session {
    const open = this.sessions.get(environment);
    if (open && !open.closed && !open.destroyed) return open;
    const session = http2.connect(this.hosts[environment]);
    const forget = () => {
      if (this.sessions.get(environment) === session) this.sessions.delete(environment);
    };
    session.on("error", (err) => {
      this.log(`[apns] ${environment} connection error: ${err.message}`);
      forget();
    });
    session.on("goaway", () => {
      // Streams already sent finish; new ones go to a new session.
      forget();
      session.close();
    });
    session.on("close", forget);
    this.sessions.set(environment, session);
    return session;
  }

  private request(
    environment: Environment,
    deviceToken: string,
    headers: Record<string, string>,
    body: string,
    jwt: string,
  ): Promise<ApnsResponse> {
    return new Promise((resolve, reject) => {
      let session: http2.ClientHttp2Session;
      try {
        session = this.session(environment);
      } catch (err) {
        reject(err);
        return;
      }
      let done = false;
      const finish = (fn: () => void) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        fn();
      };
      const req = session.request({
        ":method": "POST",
        ":path": `/3/device/${deviceToken}`,
        ...headers,
        authorization: `bearer ${jwt}`,
        "content-type": "application/json",
      });
      const timer = setTimeout(() => {
        finish(() => reject(new Error(`no answer within ${this.timeoutMs} ms`)));
        req.close(http2.constants.NGHTTP2_CANCEL);
        this.checkAlive(environment, session);
      }, this.timeoutMs);
      let status = 0;
      const chunks: Buffer[] = [];
      req.on("response", (h) => {
        status = Number(h[":status"]);
      });
      req.on("data", (chunk: Buffer) => chunks.push(chunk));
      req.on("end", () => finish(() => resolve({ status, reason: parseReason(chunks) })));
      req.on("error", (err) => finish(() => reject(err)));
      req.on("close", () => finish(() => reject(new Error("stream closed without an answer"))));
      req.end(body);
    });
  }

  /** After a timeout: a connection that doesn't answer a ping is dropped (e.g. a dead NAT entry). */
  private checkAlive(environment: Environment, session: http2.ClientHttp2Session): void {
    if (session.closed || session.destroyed) return;
    const drop = () => {
      if (this.sessions.get(environment) === session) this.sessions.delete(environment);
      session.destroy();
    };
    const timer = setTimeout(drop, 5000);
    try {
      session.ping((err) => {
        clearTimeout(timer);
        if (err) drop();
      });
    } catch {
      clearTimeout(timer);
      drop();
    }
  }
}

/** APNs' error body is {"reason": "..."}; only a plain word is kept (it goes into logs). */
function parseReason(chunks: Buffer[]): string | undefined {
  if (chunks.length === 0) return undefined;
  try {
    const reason = JSON.parse(Buffer.concat(chunks).toString("utf8"))?.reason;
    return typeof reason === "string" && /^[A-Za-z]{1,64}$/.test(reason) ? reason : undefined;
  } catch {
    return undefined;
  }
}
