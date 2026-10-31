// The family's notification channels: CRUD for the settings page. The secret (`token`) is
// sealed with lib/secrets.ts on the way in and never handed back: the DTO only says
// whether one is set, and a blank token on edit keeps the stored one.

import { randomUUID } from "node:crypto";
import { and, asc, eq, inArray } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { notificationChannels } from "@/lib/db/schema";
import { AuthError } from "@/lib/auth/errors";
import { type Actor, requireRole } from "@/lib/families/roles";
import { getSecretBox } from "@/lib/secrets";
import { type ChannelInput, missingChannelFields } from "./schema";
import type { Channel } from "./send";

export type ChannelRow = typeof notificationChannels.$inferSelect;

export interface ChannelDto {
  id: string;
  name: string;
  provider: string;
  target: string;
  enabled: boolean;
  hasToken: boolean;
  smtpHost: string;
  smtpPort: number;
  smtpUsername: string;
  smtpFrom: string;
}

export function toChannelDto(c: ChannelRow): ChannelDto {
  return {
    id: c.id,
    name: c.name,
    provider: c.provider,
    target: c.target,
    enabled: c.enabled,
    hasToken: c.token !== "",
    smtpHost: c.smtpHost,
    smtpPort: c.smtpPort,
    smtpUsername: c.smtpUsername,
    smtpFrom: c.smtpFrom,
  };
}

function validate(input: ChannelInput): void {
  const missing = missingChannelFields(input);
  if (missing.length > 0) throw new AuthError(400, `${missing[0]} is required for ${input.provider}.`);
}

export function getChannelRow(db: Db, familyId: string, channelId: string): ChannelRow {
  const c = db.select().from(notificationChannels).where(eq(notificationChannels.id, channelId)).get();
  if (!c || c.familyId !== familyId) throw new AuthError(404, "Channel not found.");
  return c;
}

/** The family's channels without their secrets (any member). */
export function listChannels(db: Db, actor: Actor, familyId: string): ChannelDto[] {
  requireRole(db, actor, familyId, "viewer");
  return listChannelRows(db, familyId).map(toChannelDto);
}

export function listChannelRows(db: Db, familyId: string): ChannelRow[] {
  return db
    .select()
    .from(notificationChannels)
    .where(eq(notificationChannels.familyId, familyId))
    .orderBy(asc(notificationChannels.createdAt), asc(notificationChannels.name))
    .all();
}

export function createChannel(db: Db, actor: Actor, familyId: string, input: ChannelInput, now: Date): { id: string } {
  requireRole(db, actor, familyId, "editor");
  validate(input);
  const id = randomUUID();
  db.insert(notificationChannels)
    .values({ id, familyId, ...input, token: getSecretBox().seal(input.token), createdAt: now })
    .run();
  return { id };
}

export function updateChannel(db: Db, actor: Actor, familyId: string, channelId: string, input: ChannelInput): void {
  requireRole(db, actor, familyId, "editor");
  const existing = getChannelRow(db, familyId, channelId);
  // A blank token on edit means "keep the stored secret" — the UI never round-trips it.
  const keep = !input.token;
  validate({ ...input, token: keep ? (existing.token ? "set" : "") : input.token });
  db.update(notificationChannels)
    .set({ ...input, token: keep ? existing.token : getSecretBox().seal(input.token) })
    .where(eq(notificationChannels.id, channelId))
    .run();
}

export function deleteChannel(db: Db, actor: Actor, familyId: string, channelId: string): void {
  requireRole(db, actor, familyId, "editor");
  getChannelRow(db, familyId, channelId);
  db.delete(notificationChannels).where(eq(notificationChannels.id, channelId)).run();
}

/** The family's enabled channels (all, or those in `ids`) with their secrets opened. */
export function openChannels(db: Db, familyId: string, ids?: string[]): OpenChannel[] {
  if (ids && ids.length === 0) return [];
  const rows = db
    .select()
    .from(notificationChannels)
    .where(
      and(
        eq(notificationChannels.familyId, familyId),
        eq(notificationChannels.enabled, true),
        ids ? inArray(notificationChannels.id, ids) : undefined,
      ),
    )
    .all();
  return rows.map(openChannel);
}

export type OpenChannel = Channel & { id: string; name: string; error?: string };

/** A channel row with its secret opened (or `error` when it can't be). */
export function openChannel(row: ChannelRow): OpenChannel {
  try {
    return { ...row, token: getSecretBox().open(row.token) };
  } catch {
    // Sealed with another key (ENCRYPTION_KEY / AUTH_SECRET changed): enter the token again.
    return { ...row, token: "", error: "The stored token can't be decrypted; enter it again." };
  }
}
