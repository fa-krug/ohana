// The app devices that get push notifications (phase 9), one per API token: the app registers
// with the relay, then gives this server the relay's token for it and a key for the payloads
// (PUT /api/v1/me/push). Both are sealed at rest. The device goes with its API token (sign out,
// revoking it on the account page) or when the relay says it's gone.

import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { z } from "zod";
import type { Db } from "@/lib/db";
import { pushDevices } from "@/lib/db/schema";
import { HttpError } from "@/lib/api/http";
import { getSecretBox } from "@/lib/secrets";
import { pushRelayUrl, sameRelay } from "./config";

export type PushDeviceRow = typeof pushDevices.$inferSelect;

export const PUSH_PLATFORMS = ["ios", "macos"] as const;

const familyIds = z.array(z.string().min(1).max(100)).max(500);

export const pushRegistrationSchema = z.object({
  /** The relay the app registered with: must be this server's (PUSH_RELAY_URL). */
  relay: z.string().trim().min(1).max(500),
  relayToken: z
    .string()
    .trim()
    .min(4)
    .max(2000)
    .regex(/^r1\.[A-Za-z0-9_-]+$/, "relayToken isn't one of the relay's"),
  /** The device's AES-256 key, base64. */
  key: z
    .string()
    .trim()
    .refine((k) => /^[A-Za-z0-9+/]+=*$/.test(k) && Buffer.from(k, "base64").length === 32, "key must be 32 bytes, base64"),
  platform: z.enum(PUSH_PLATFORMS),
  mutedFamilyIds: familyIds.optional(),
});

export const pushMuteSchema = z.object({ mutedFamilyIds: familyIds });

export interface PushDeviceDto {
  registered: boolean;
  platform: string | null;
  mutedFamilyIds: string[];
  lastSentAt: Date | null;
  lastError: string | null;
}

export function mutedOf(row: Pick<PushDeviceRow, "mutedFamilyIds">): string[] {
  try {
    const ids = JSON.parse(row.mutedFamilyIds) as unknown;
    return Array.isArray(ids) ? ids.filter((x): x is string => typeof x === "string") : [];
  } catch {
    return [];
  }
}

export function deviceDto(row: PushDeviceRow | undefined): PushDeviceDto {
  return {
    registered: !!row,
    platform: row?.platform ?? null,
    mutedFamilyIds: row ? mutedOf(row) : [],
    lastSentAt: row?.lastSentAt ?? null,
    lastError: row?.lastError ?? null,
  };
}

export function deviceOfToken(db: Db, tokenId: string): PushDeviceRow | undefined {
  return db.select().from(pushDevices).where(eq(pushDevices.tokenId, tokenId)).get();
}

/** The relay this server sends through; 404 when push to the app is off. */
export function requireRelay(): string {
  const relay = pushRelayUrl();
  if (!relay) throw new HttpError(404, "Push notifications are turned off on this server.");
  return relay;
}

/** Registers (or renews) the device of an API token. */
export function registerDevice(
  db: Db,
  user: { id: string },
  tokenId: string,
  raw: unknown,
  now: Date,
): PushDeviceRow {
  const relay = requireRelay();
  const input = pushRegistrationSchema.parse(raw);
  // The server only ever posts to its own relay, never to a URL a client names.
  if (!sameRelay(input.relay, relay)) throw new HttpError(409, `This server sends push notifications through ${relay}.`);
  const box = getSecretBox();
  const values = {
    platform: input.platform,
    relayToken: box.seal(input.relayToken),
    key: box.seal(input.key),
    ...(input.mutedFamilyIds ? { mutedFamilyIds: JSON.stringify([...new Set(input.mutedFamilyIds)]) } : {}),
    updatedAt: now,
    lastError: null,
  };
  db.insert(pushDevices)
    .values({ id: randomUUID(), userId: user.id, tokenId, createdAt: now, ...values })
    .onConflictDoUpdate({ target: pushDevices.tokenId, set: values })
    .run();
  return deviceOfToken(db, tokenId)!;
}

export function setMuted(db: Db, tokenId: string, raw: unknown, now: Date): PushDeviceRow {
  const { mutedFamilyIds } = pushMuteSchema.parse(raw);
  const row = deviceOfToken(db, tokenId);
  if (!row) throw new HttpError(404, "This device doesn't get push notifications.");
  db.update(pushDevices)
    .set({ mutedFamilyIds: JSON.stringify([...new Set(mutedFamilyIds)]), updatedAt: now })
    .where(eq(pushDevices.id, row.id))
    .run();
  return deviceOfToken(db, tokenId)!;
}

export function deleteDeviceOfToken(db: Db, tokenId: string): void {
  db.delete(pushDevices).where(eq(pushDevices.tokenId, tokenId)).run();
}

/** A device's relay token and key, opened; null when they can't be (e.g. a changed secret key). */
export function openDevice(row: PushDeviceRow): { relayToken: string; key: Buffer } | null {
  try {
    const box = getSecretBox();
    const key = Buffer.from(box.open(row.key), "base64");
    const relayToken = box.open(row.relayToken);
    return key.length === 32 && relayToken ? { relayToken, key } : null;
  } catch {
    return null;
  }
}
