import { createHash, randomBytes, randomUUID } from "node:crypto";
import { and, eq, isNotNull, lt, ne } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { authTokens, users } from "@/lib/db/schema";
import { SESSION_TTL_MS, SETUP_TTL_MS } from "./config";

export type User = typeof users.$inferSelect;
export type AuthToken = typeof authTokens.$inferSelect;
export type TokenKind = "session" | "api" | "setup";

/** API tokens carry a prefix so they're recognizable in scripts and secret scanners. */
const PREFIX: Record<TokenKind, string> = { session: "", api: "ohana_", setup: "" };

export function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export function createToken(
  db: Db,
  args: { userId: string; kind: TokenKind; name?: string; canReset?: boolean; ttlMs?: number | null },
  now: Date,
): { token: string; row: AuthToken } {
  const token = PREFIX[args.kind] + randomBytes(32).toString("base64url");
  const ttl =
    args.ttlMs !== undefined ? args.ttlMs : args.kind === "session" ? SESSION_TTL_MS : args.kind === "setup" ? SETUP_TTL_MS : null;
  const row = db
    .insert(authTokens)
    .values({
      id: randomUUID(),
      hash: hashToken(token),
      userId: args.userId,
      kind: args.kind,
      name: args.name ?? "",
      canReset: args.canReset ?? false,
      createdAt: now,
      expiresAt: ttl === null ? null : new Date(now.getTime() + ttl),
    })
    .returning()
    .get();
  return { token, row };
}

/** The token's row and user, if the token exists, has this kind and hasn't expired. */
export function findToken(
  db: Db,
  token: string,
  kind: TokenKind,
  now: Date,
): { token: AuthToken; user: User } | null {
  const row = db
    .select({ token: authTokens, user: users })
    .from(authTokens)
    .innerJoin(users, eq(users.id, authTokens.userId))
    .where(and(eq(authTokens.hash, hashToken(token)), eq(authTokens.kind, kind)))
    .get();
  if (!row) return null;
  if (row.token.expiresAt && row.token.expiresAt.getTime() <= now.getTime()) {
    deleteToken(db, row.token.id);
    return null;
  }
  return row;
}

/** Marks a token as used, at most once a minute (every request would mean a write each). */
export function touchToken(db: Db, row: AuthToken, now: Date): void {
  if (row.lastUsedAt && now.getTime() - row.lastUsedAt.getTime() < 60_000) return;
  db.update(authTokens).set({ lastUsedAt: now }).where(eq(authTokens.id, row.id)).run();
}

export function deleteToken(db: Db, id: string): void {
  db.delete(authTokens).where(eq(authTokens.id, id)).run();
}

/** Deletes one of a user's tokens; false if there is no such token. */
export function deleteOwnToken(db: Db, userId: string, id: string, kind: TokenKind): boolean {
  return (
    db
      .delete(authTokens)
      .where(and(eq(authTokens.id, id), eq(authTokens.userId, userId), eq(authTokens.kind, kind)))
      .run().changes > 0
  );
}

export function listTokens(db: Db, userId: string, kind: TokenKind): AuthToken[] {
  return db
    .select()
    .from(authTokens)
    .where(and(eq(authTokens.userId, userId), eq(authTokens.kind, kind)))
    .orderBy(authTokens.createdAt)
    .all();
}

/** Deletes a user's tokens of one kind, except `keepId` (e.g. the session making the change). */
export function deleteUserTokens(db: Db, userId: string, kind: TokenKind, keepId?: string): void {
  const where = [eq(authTokens.userId, userId), eq(authTokens.kind, kind)];
  if (keepId) where.push(ne(authTokens.id, keepId));
  db.delete(authTokens).where(and(...where)).run();
}

export function deleteExpiredTokens(db: Db, now: Date): number {
  return db
    .delete(authTokens)
    .where(and(isNotNull(authTokens.expiresAt), lt(authTokens.expiresAt, now)))
    .run().changes;
}
