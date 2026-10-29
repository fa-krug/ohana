// Encrypts secrets before they are stored: notification channel tokens and SMTP passwords
// now, the assistant's API keys later. Port of family-planner's `_shared/secrets.ts`
// (SecretBox): AES-256-GCM, stored as "v1:<base64 of 12-byte IV + ciphertext + 16-byte tag>"
// — the same format WebCrypto produces, so family-planner's sealed values open here with
// its old key (the import re-seals them with Ohana's).
//
// The key: `ENCRYPTION_KEY` (32 random bytes, base64: `openssl rand -base64 32`), or, when
// that isn't set, one derived from `AUTH_SECRET` with HKDF-SHA256 (info "ohana-secrets"), so
// a deployment needs no extra secret. Changing the key (or AUTH_SECRET without an
// ENCRYPTION_KEY) makes the stored secrets unreadable: they have to be entered again.

import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from "node:crypto";
import { getAuthSecret } from "@/lib/auth/config";

const PREFIX = "v1:";
const IV_BYTES = 12;
const TAG_BYTES = 16;

export class SecretBox {
  private readonly key: Buffer;

  /** `secret`: 32 random bytes as base64 (e.g. `openssl rand -base64 32`). */
  constructor(secret: string) {
    const raw = Buffer.from(secret.trim(), "base64");
    if (raw.length !== 32) throw new Error("ENCRYPTION_KEY must be 32 bytes, base64-encoded");
    this.key = raw;
  }

  /** A box keyed by raw key bytes (e.g. from HKDF). */
  static fromKey(key: Uint8Array): SecretBox {
    return new SecretBox(Buffer.from(key).toString("base64"));
  }

  seal(plain: string): string {
    if (!plain) return "";
    const iv = randomBytes(IV_BYTES);
    const cipher = createCipheriv("aes-256-gcm", this.key, iv);
    const data = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]);
    return PREFIX + Buffer.concat([iv, data, cipher.getAuthTag()]).toString("base64");
  }

  open(sealed: string): string {
    if (!sealed) return "";
    if (!sealed.startsWith(PREFIX)) throw new Error("Unknown secret format");
    const bytes = Buffer.from(sealed.slice(PREFIX.length), "base64");
    if (bytes.length < IV_BYTES + TAG_BYTES) throw new Error("Malformed secret");
    const decipher = createDecipheriv("aes-256-gcm", this.key, bytes.subarray(0, IV_BYTES));
    decipher.setAuthTag(bytes.subarray(bytes.length - TAG_BYTES));
    return Buffer.concat([
      decipher.update(bytes.subarray(IV_BYTES, bytes.length - TAG_BYTES)),
      decipher.final(),
    ]).toString("utf8");
  }
}

/** Whether a stored value is sealed (as opposed to empty). */
export function isSealed(value: string): boolean {
  return value.startsWith(PREFIX);
}

/** The 32-byte key derived from AUTH_SECRET (used when ENCRYPTION_KEY isn't set). */
export function deriveKey(authSecret: string): Buffer {
  return Buffer.from(hkdfSync("sha256", authSecret, Buffer.alloc(0), "ohana-secrets", 32));
}

let cached: { source: string; box: SecretBox } | null = null;

/** The app's SecretBox, from ENCRYPTION_KEY or else derived from AUTH_SECRET. */
export function getSecretBox(): SecretBox {
  const explicit = process.env.ENCRYPTION_KEY?.trim();
  const source = explicit ? `key:${explicit}` : `auth:${getAuthSecret()}`;
  if (cached?.source !== source) {
    cached = { source, box: explicit ? new SecretBox(explicit) : SecretBox.fromKey(deriveKey(getAuthSecret())) };
  }
  return cached.box;
}

/** A random key for local development and tests. */
export function devSecret(): string {
  return randomBytes(32).toString("base64");
}
