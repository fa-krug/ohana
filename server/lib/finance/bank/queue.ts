// The syncs of linked accounts (fin_bank_syncs): the app starts one (waiting), the worker's
// BankSyncRunner (runner.ts) runs it (running, tan while the bank wants a TAN) until it is done
// or failed; the app polls its row. Finished ones are kept a day.

import { randomUUID } from "node:crypto";
import { and, desc, eq, inArray, lte, sql } from "drizzle-orm";
import { HttpError } from "@/lib/api/http";
import type { Db } from "@/lib/db";
import { finBankSyncs } from "@/lib/db/schema";
import { getSecretBox } from "@/lib/secrets";
import { BANK_MAX_UNCONFIRMED, LOGIN_REFUSED_MESSAGE, UNCONFIRMED_MESSAGE, getLink } from "./links";
import type { SyncStep, TanChallenge } from "./types";

/** Finished syncs are kept this long. */
export const SYNC_KEEP_MS = 24 * 60 * 60_000;
/** A waiting sync no worker took up within this long is given up when a new one is started. */
const STALE_WAITING_MS = 5 * 60_000;

export const ACTIVE = ["waiting", "running", "tan"] as const;
export type SyncStatus = (typeof ACTIVE)[number] | "done" | "failed";

export type SyncRow = typeof finBankSyncs.$inferSelect;

export interface SyncResult {
  added: number;
  duplicates: number;
  transfers: number;
  splits: number;
  ids: string[];
}

export interface SyncDto {
  id: string;
  accountId: string;
  status: SyncStatus;
  step: SyncStep | null;
  tan: TanChallenge | null;
  result: SyncResult | null;
  error: string | null;
  createdAt: string;
  updatedAt: string;
}

function parse<T>(text: string | null): T | null {
  if (!text) return null;
  try {
    return JSON.parse(text) as T;
  } catch {
    return null;
  }
}

export function syncDto(r: SyncRow): SyncDto {
  return {
    id: r.id,
    accountId: r.accountId,
    status: r.status as SyncStatus,
    step: (r.step as SyncStep | null) ?? null,
    tan: r.status === "tan" ? parse<TanChallenge>(r.tan) : null,
    result: r.status === "done" ? parse<SyncResult>(r.result) : null,
    error: r.error,
    createdAt: r.createdAt.toISOString(),
    updatedAt: r.updatedAt.toISOString(),
  };
}

const ofAccount = (familyId: string, accountId: string) =>
  and(eq(finBankSyncs.familyId, familyId), eq(finBankSyncs.accountId, accountId));

/** The account's latest sync (any status). */
export function latestSync(db: Db, familyId: string, accountId: string): SyncRow | undefined {
  return db
    .select()
    .from(finBankSyncs)
    .where(ofAccount(familyId, accountId))
    .orderBy(desc(finBankSyncs.createdAt), desc(sql`rowid`))
    .get();
}

/** The account's sync that hasn't ended, if any. */
export function activeSync(db: Db, familyId: string, accountId: string): SyncRow | undefined {
  return db
    .select()
    .from(finBankSyncs)
    .where(and(ofAccount(familyId, accountId), inArray(finBankSyncs.status, [...ACTIVE])))
    .orderBy(desc(finBankSyncs.createdAt), desc(sql`rowid`))
    .get();
}

/** What a sync that failed (or was cancelled) is set to. */
export const failedSet = (error: string, now: Date) => ({
  status: "failed",
  step: null,
  tan: null,
  tanInput: null,
  error,
  runToken: null,
  lockedUntil: null,
  updatedAt: now,
});

/**
 * Starts a sync of the linked account: the one that hasn't ended yet if there is one (created:
 * false), else a new waiting one. 409 without a link, and while a lockout guard holds (the
 * bank refused the login last time; too many TAN challenges without a confirmed TAN).
 */
export function startSync(
  db: Db,
  familyId: string,
  accountId: string,
  userId: string | null,
  now: Date,
): { sync: SyncRow; created: boolean } {
  // Synchronous (better-sqlite3), so no other request comes in between.
  const link = getLink(db, familyId, accountId);
  if (!link) throw new HttpError(409, "This account isn't linked to a bank");
  const active = activeSync(db, familyId, accountId);
  if (active) {
    if (!(active.status === "waiting" && now.getTime() - active.createdAt.getTime() > STALE_WAITING_MS)) {
      return { sync: active, created: false };
    }
    // Nobody took it up (no worker running?): it gives way to the new one.
    db.update(finBankSyncs)
      .set(failedSet("The sync didn't start", now))
      .where(and(eq(finBankSyncs.id, active.id), eq(finBankSyncs.status, "waiting")))
      .run();
  }
  if (link.loginRefused) throw new HttpError(409, LOGIN_REFUSED_MESSAGE);
  if (link.unconfirmedTans >= BANK_MAX_UNCONFIRMED) throw new HttpError(409, UNCONFIRMED_MESSAGE);
  const row: SyncRow = {
    id: randomUUID(),
    familyId,
    accountId,
    userId,
    status: "waiting",
    step: null,
    tan: null,
    tanInput: null,
    result: null,
    error: null,
    runToken: null,
    lockedUntil: null,
    createdAt: now,
    updatedAt: now,
  };
  db.insert(finBankSyncs).values(row).run();
  return { sync: row, created: true };
}

/** Cancels the account's sync that hasn't ended (the worker notices at its next tick); returns
 *  it, or the latest one when none runs. */
export function cancelSync(db: Db, familyId: string, accountId: string, now: Date): SyncRow | undefined {
  cancelActive(db, familyId, accountId, now);
  return latestSync(db, familyId, accountId);
}

/** Marks the account's syncs that haven't ended failed ("Cancelled"). */
export function cancelActive(db: Db, familyId: string, accountId: string, now: Date): void {
  db.update(finBankSyncs)
    .set(failedSet("Cancelled", now))
    .where(and(ofAccount(familyId, accountId), inArray(finBankSyncs.status, [...ACTIVE])))
    .run();
}

/** The TAN the user typed, for the worker; 409 unless the sync waits for a typed one. */
export function submitTan(db: Db, familyId: string, accountId: string, rawTan: unknown, now: Date): SyncRow {
  if (typeof rawTan !== "string") throw new HttpError(400, "tan is required");
  const tan = rawTan.replace(/\s+/g, "");
  if (!/^[0-9A-Za-z]{1,32}$/.test(tan)) throw new HttpError(400, "tan doesn't look like a TAN");
  const sync = activeSync(db, familyId, accountId);
  const challenge = sync?.status === "tan" ? parse<TanChallenge>(sync.tan) : null;
  if (!sync || !challenge || challenge.type === "push") throw new HttpError(409, "No TAN is asked for");
  if (sync.tanInput) throw new HttpError(409, "The TAN was sent already");
  const set = { tanInput: getSecretBox().seal(tan), updatedAt: now };
  const changed = db
    .update(finBankSyncs)
    .set(set)
    .where(and(eq(finBankSyncs.id, sync.id), eq(finBankSyncs.status, "tan"), sql`${finBankSyncs.tanInput} is null`))
    .run().changes;
  if (!changed) throw new HttpError(409, "No TAN is asked for");
  return { ...sync, ...set };
}

/** Removes finished syncs older than SYNC_KEEP_MS (cleanup). */
export function pruneSyncs(db: Db, now: Date): number {
  return db
    .delete(finBankSyncs)
    .where(
      and(
        inArray(finBankSyncs.status, ["done", "failed"]),
        lte(finBankSyncs.updatedAt, new Date(now.getTime() - SYNC_KEEP_MS)),
      ),
    )
    .run().changes;
}
