// Relay tokens: what the app gets from /v1/register and hands to its server, and what servers
// send to. "r1." + base64url (no padding) of 12-byte IV ‖ AES-256-GCM ciphertext ‖ 16-byte tag
// of {"t": APNs token (lowercase hex), "e": environment, "p": platform, "iat": unix seconds},
// sealed with RELAY_SECRET. Servers never see the APNs token, and the relay needs no database:
// it only takes tokens it sealed itself. While RELAY_SECRET is being rotated, tokens sealed
// with RELAY_SECRET_OLD still open; new ones are always sealed with RELAY_SECRET.

import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

export type Environment = "production" | "sandbox";
export type Platform = "ios" | "macos";

export type Device = {
  apnsToken: string;
  environment: Environment;
  platform: Platform;
  /** When the token was issued (unix seconds). */
  issuedAt: number;
};

export type Secrets = {
  /** Seals and opens. */
  current: Buffer;
  /** Only opens (while rotating). */
  old?: Buffer;
};

const PREFIX = "r1.";
const IV_BYTES = 12;
const TAG_BYTES = 16;

export const APNS_TOKEN_RE = /^[0-9a-f]{64,200}$/;

export function sealToken(secrets: Secrets, device: Device): string {
  const plain = JSON.stringify({
    t: device.apnsToken,
    e: device.environment,
    p: device.platform,
    iat: device.issuedAt,
  });
  const iv = randomBytes(IV_BYTES);
  const cipher = createCipheriv("aes-256-gcm", secrets.current, iv);
  const data = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]);
  return PREFIX + Buffer.concat([iv, data, cipher.getAuthTag()]).toString("base64url");
}

/** The device inside a relay token, or null when it isn't one of ours (or was tampered with). */
export function openToken(secrets: Secrets, token: string): Device | null {
  if (typeof token !== "string" || !token.startsWith(PREFIX) || token.length > 1024) return null;
  const body = token.slice(PREFIX.length);
  if (!/^[A-Za-z0-9_-]+$/.test(body)) return null;
  const bytes = Buffer.from(body, "base64url");
  if (bytes.length <= IV_BYTES + TAG_BYTES) return null;
  for (const key of [secrets.current, secrets.old]) {
    if (!key) continue;
    const plain = decrypt(key, bytes);
    if (plain !== null) return parseDevice(plain);
  }
  return null;
}

function decrypt(key: Buffer, bytes: Buffer): string | null {
  try {
    const decipher = createDecipheriv("aes-256-gcm", key, bytes.subarray(0, IV_BYTES));
    decipher.setAuthTag(bytes.subarray(bytes.length - TAG_BYTES));
    return Buffer.concat([
      decipher.update(bytes.subarray(IV_BYTES, bytes.length - TAG_BYTES)),
      decipher.final(),
    ]).toString("utf8");
  } catch {
    return null;
  }
}

function parseDevice(plain: string): Device | null {
  let data: unknown;
  try {
    data = JSON.parse(plain);
  } catch {
    return null;
  }
  if (!data || typeof data !== "object") return null;
  const { t, e, p, iat } = data as Record<string, unknown>;
  if (typeof t !== "string" || !APNS_TOKEN_RE.test(t)) return null;
  if (e !== "production" && e !== "sandbox") return null;
  if (p !== "ios" && p !== "macos") return null;
  if (typeof iat !== "number" || !Number.isInteger(iat)) return null;
  return { apnsToken: t, environment: e, platform: p, issuedAt: iat };
}
