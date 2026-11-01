// What a push carries (phase 9), sealed for one device: the relay and Apple only ever see
// ciphertext. AES-256-GCM with the device's key (32 bytes the app made and gave only to this
// server); the bytes are 12-byte IV + ciphertext + 16-byte tag, base64 — the layout CryptoKit's
// `AES.GCM.SealedBox(combined:)` reads (apple/Ohana/Core/Push/PushPayload.swift).

import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";

export interface PushPayload {
  v: 1;
  title: string;
  body: string;
  /** Where a tap leads: a path of this server (`/f/{id}/…`), which the app routes. */
  path?: string;
  familyId?: string;
  /** The notification event (`appointment_found`, …), when it is one. */
  event?: string;
}

const IV_BYTES = 12;
const TAG_BYTES = 16;
/** The relay takes payloads of at most 4000 base64 characters, 3000 bytes. */
export const MAX_SEALED_BYTES = 3000;
const MAX_PLAIN_BYTES = MAX_SEALED_BYTES - IV_BYTES - TAG_BYTES;

export function seal(key: Buffer, plain: Buffer, iv: Buffer = randomBytes(IV_BYTES)): string {
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const data = Buffer.concat([cipher.update(plain), cipher.final()]);
  return Buffer.concat([iv, data, cipher.getAuthTag()]).toString("base64");
}

export function open(key: Buffer, sealed: string): Buffer {
  const bytes = Buffer.from(sealed, "base64");
  if (bytes.length < IV_BYTES + TAG_BYTES) throw new Error("Malformed payload");
  const decipher = createDecipheriv("aes-256-gcm", key, bytes.subarray(0, IV_BYTES));
  decipher.setAuthTag(bytes.subarray(bytes.length - TAG_BYTES));
  return Buffer.concat([decipher.update(bytes.subarray(IV_BYTES, bytes.length - TAG_BYTES)), decipher.final()]);
}

function encode(p: PushPayload): Buffer {
  return Buffer.from(JSON.stringify(p), "utf8");
}

/** The longest start of `s` (plus "…") for which `fits` holds; "" when none does. */
function longestFitting(s: string, fits: (t: string) => boolean): string {
  const chars = [...s];
  let lo = 0;
  let hi = chars.length - 1;
  let best = "";
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const t = mid > 0 ? chars.slice(0, mid).join("").trimEnd() + "…" : "";
    if (fits(t)) {
      best = t;
      lo = mid + 1;
    } else hi = mid - 1;
  }
  return best;
}

/** The payload as JSON, the body (then the title) shortened until it fits the relay's limit. */
export function payloadBytes(p: PushPayload): Buffer {
  const fits = (q: PushPayload) => encode(q).length <= MAX_PLAIN_BYTES;
  if (fits(p)) return encode(p);
  let q: PushPayload = { ...p, body: longestFitting(p.body, (body) => fits({ ...p, body })) };
  if (!fits(q)) q = { ...q, title: longestFitting(q.title, (title) => fits({ ...q, title })) };
  return encode(q);
}

/** The payload sealed for a device (base64). */
export function sealPayload(key: Buffer, p: PushPayload): string {
  return seal(key, payloadBytes(p));
}

export function openPayload(key: Buffer, sealed: string): PushPayload {
  return JSON.parse(open(key, sealed).toString("utf8")) as PushPayload;
}

/** An APNs collapse id that says nothing to the relay or Apple: a hash of the device key and
 *  what should replace an earlier notification (a chat, a search, a day). */
export function collapseIdFor(key: Buffer, collapseKey: string): string {
  return createHash("sha256").update(key).update(collapseKey, "utf8").digest("base64url").slice(0, 22);
}

/** The path a message's link leads to on this server (`https://host/f/x?y` → `/f/x?y`). */
export function pathOfUrl(url: string): string | undefined {
  if (!url) return undefined;
  if (url.startsWith("/")) return url;
  try {
    const u = new URL(url);
    return u.pathname + u.search;
  } catch {
    return undefined;
  }
}
