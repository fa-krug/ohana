// The worker's bank sync loop (like the recipe imports' ImportRunner): every tick renews the
// leases of the syncs it runs (aborting those whose row was cancelled or deleted), fails the
// syncs another worker lost and claims the waiting ones with a compare-and-swap UPDATE (status,
// run token, lease), running each WITHOUT awaiting.
//
// A sync is never run twice: the bank counts TAN challenges, and a few without a confirmed TAN
// lock the online banking. So a lost one (its worker died, or this one stops) is marked failed
// ("Interrupted"), and nothing the bank is asked for that could raise a challenge is retried.

import { randomUUID } from "node:crypto";
import { setTimeout as sleep } from "node:timers/promises";
import { and, asc, eq, inArray, lte, sql } from "drizzle-orm";
import { randomToken } from "@/lib/api/http";
import { addDays } from "@/lib/calendar/dates";
import type { Db } from "@/lib/db";
import { finBankLinks, finBankSyncs, finTransactions } from "@/lib/db/schema";
import { importHashes, importHashOf, importTransactions } from "@/lib/finance/finance";
import { DrizzleFinanceStore, type TransactionRow } from "@/lib/finance/store";
import { getSecretBox } from "@/lib/secrets";
import { moduleEnabled } from "@/lib/server-info";
import { BANK_MAX_UNCONFIRMED, LOGIN_REFUSED_MESSAGE, UNCONFIRMED_MESSAGE, type LinkRow, getLink, openCredentials, openSession, sealSession } from "./links";
import { PROVIDERS } from "./providers";
import { type SyncResult, type SyncRow, failedSet } from "./queue";
import { BankError, type BankProvider, type BankStatement, type SyncHooks, type SyncTiming } from "./types";

/** The lease a running sync holds; renewed every tick. */
export const SYNC_LEASE_MS = 60_000;
/** How long one sync may take (a TAN may take 5 minutes). */
export const SYNC_TIMEOUT_MS = 12 * 60_000;
/** Later syncs start this many days before the last booking day imported (late bookings). */
export const RESYNC_DAYS = 14;
/** The first sync of an empty account goes this far back. */
export const FIRST_SYNC_DAYS = 730;

const DEFAULT_TIMING: SyncTiming = {
  requestTimeoutMs: 30_000,
  tanTimeoutMs: 5 * 60_000,
  pushPollMs: 2000,
};

export interface BankSyncRunnerOptions {
  /** The network (tests: the fake comdirect). */
  fetch?: typeof fetch;
  providers?: Record<string, BankProvider>;
  now?: () => Date;
  leaseMs?: number;
  timeoutMs?: number;
  timing?: Partial<SyncTiming>;
  /** How often the row is looked at for a typed TAN. */
  tanPollMs?: number;
  maxConcurrent?: number;
  log?: (msg: string) => void;
}

interface Running {
  abort: AbortController;
  token: string;
}

/** The server's local day of `d`. */
function localDay(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export class BankSyncRunner {
  private readonly running = new Map<string, Running>();
  private readonly done = new Map<string, Promise<void>>();
  private stopped = false;
  private readonly fetch: typeof fetch;
  private readonly providers: Record<string, BankProvider>;
  private readonly now: () => Date;
  private readonly leaseMs: number;
  private readonly timeoutMs: number;
  private readonly timing: SyncTiming;
  private readonly tanPollMs: number;
  private readonly maxConcurrent: number;
  private readonly log: (msg: string) => void;

  constructor(
    private readonly db: Db,
    opts: BankSyncRunnerOptions = {},
  ) {
    this.fetch = opts.fetch ?? fetch;
    this.providers = opts.providers ?? PROVIDERS;
    this.now = opts.now ?? (() => new Date());
    this.leaseMs = opts.leaseMs ?? SYNC_LEASE_MS;
    this.timeoutMs = opts.timeoutMs ?? SYNC_TIMEOUT_MS;
    this.timing = { ...DEFAULT_TIMING, ...opts.timing };
    this.tanPollMs = opts.tanPollMs ?? 250;
    this.maxConcurrent = opts.maxConcurrent ?? Math.max(1, Number(process.env.BANK_SYNC_MAX_CONCURRENT) || 4);
    this.log = opts.log ?? ((m) => console.log(`[bank] ${m}`));
  }

  get active(): number {
    return this.running.size;
  }

  /** Renews the leases of its own syncs, fails lost ones, then claims and starts waiting ones;
   *  returns how many were started. Never throws. */
  tick(now = this.now()): number {
    if (this.stopped || !moduleEnabled("finance")) return 0;
    let started = 0;
    try {
      for (const [id, run] of this.running) {
        const held = this.db
          .update(finBankSyncs)
          .set({ lockedUntil: new Date(now.getTime() + this.leaseMs) })
          .where(and(eq(finBankSyncs.id, id), eq(finBankSyncs.runToken, run.token)))
          .run().changes === 1;
        if (!held) run.abort.abort("lost");
      }
      const lost = this.db
        .select()
        .from(finBankSyncs)
        .where(and(inArray(finBankSyncs.status, ["running", "tan"]), lte(finBankSyncs.lockedUntil, now)))
        .all();
      for (const row of lost) {
        if (this.running.has(row.id)) continue;
        const failed = this.db
          .update(finBankSyncs)
          .set(failedSet("Interrupted", now))
          .where(and(eq(finBankSyncs.id, row.id), eq(finBankSyncs.status, row.status), heldBy(row.runToken)))
          .run().changes === 1;
        if (failed) this.log(`sync ${row.id} was interrupted (its worker went away)`);
      }
      const waiting = this.db
        .select()
        .from(finBankSyncs)
        .where(eq(finBankSyncs.status, "waiting"))
        .orderBy(asc(finBankSyncs.createdAt), asc(sql`rowid`))
        .all();
      for (const row of waiting) {
        if (this.running.size >= this.maxConcurrent) break;
        if (this.start(row, now)) started += 1;
      }
    } catch (err) {
      console.error("[bank] tick failed:", err);
    }
    return started;
  }

  private start(row: SyncRow, now: Date): boolean {
    const token = randomToken(32);
    const claimed = this.db
      .update(finBankSyncs)
      .set({ status: "running", step: "login", runToken: token, lockedUntil: new Date(now.getTime() + this.leaseMs), updatedAt: now })
      .where(and(eq(finBankSyncs.id, row.id), eq(finBankSyncs.status, "waiting"), heldBy(row.runToken)))
      .run().changes === 1;
    if (!claimed) return false;
    const run: Running = { abort: new AbortController(), token };
    this.running.set(row.id, run);
    const p = this.run(row, run)
      .catch((err) => console.error(`[bank] sync ${row.id} failed:`, err))
      .finally(() => {
        this.running.delete(row.id);
        this.done.delete(row.id);
      });
    this.done.set(row.id, p);
    return true;
  }

  private async run(row: SyncRow, run: Running): Promise<void> {
    const timeout = AbortSignal.timeout(this.timeoutMs);
    const signal = AbortSignal.any([run.abort.signal, timeout]);
    const mine = and(eq(finBankSyncs.id, row.id), eq(finBankSyncs.runToken, run.token));
    /** Changes the row while this run still holds it; else stops the run. */
    const update = (set: Partial<SyncRow>) => {
      const held = this.db.update(finBankSyncs).set({ ...set, updatedAt: this.now() }).where(mine).run().changes === 1;
      if (!held) {
        run.abort.abort("lost");
        throw new Error("The sync was cancelled");
      }
    };
    try {
      const link = getLink(this.db, row.familyId, row.accountId);
      if (!link) throw new BankError("This account isn't linked to a bank anymore");
      const provider = Object.hasOwn(this.providers, link.provider) ? this.providers[link.provider] : undefined;
      if (!provider) throw new BankError(`Ohana doesn't know the bank "${link.provider}"`);
      if (link.loginRefused) throw new BankError(LOGIN_REFUSED_MESSAGE);
      if (link.unconfirmedTans >= BANK_MAX_UNCONFIRMED) throw new BankError(UNCONFIRMED_MESSAGE);
      const credentials = openCredentials(link);
      if (!credentials) throw new BankError("The bank connection can't be read any more: save it again");
      const statement = await provider.fetchStatement({
        credentials,
        iban: link.iban,
        session: openSession(link),
        from: this.firstDay(link),
        signal,
        fetch: this.fetch,
        now: this.now,
        timing: this.timing,
        hooks: this.hooks(link, row.id, run, signal, update),
      });
      update({ status: "running", step: "import", tan: null });
      const result = await this.import(link, statement);
      update({ status: "done", step: null, tanInput: null, result: JSON.stringify(result), runToken: null, lockedUntil: null });
    } catch (err) {
      if (run.abort.signal.aborted) {
        // Cancelled or deleted: nothing to tell. The worker stops: interrupted, never run again.
        if (run.abort.signal.reason === "stop") {
          this.db.update(finBankSyncs).set(failedSet("Interrupted", this.now())).where(mine).run();
        }
        return;
      }
      const message = timeout.aborted
        ? "The sync took too long"
        : err instanceof BankError
          ? err.message
          : "The sync failed";
      if (!(err instanceof BankError) && !timeout.aborted) console.error(`[bank] sync ${row.id} failed:`, err);
      this.db.update(finBankSyncs).set(failedSet(message, this.now())).where(mine).run();
    }
  }

  private hooks(
    link: LinkRow,
    id: string,
    run: Running,
    signal: AbortSignal,
    update: (set: Partial<SyncRow>) => void,
  ): SyncHooks {
    const linkKey = and(eq(finBankLinks.familyId, link.familyId), eq(finBankLinks.accountId, link.accountId));
    const current = () =>
      this.db
        .select({ runToken: finBankSyncs.runToken, tanInput: finBankSyncs.tanInput })
        .from(finBankSyncs)
        .where(eq(finBankSyncs.id, id))
        .get();
    const assertHeld = () => {
      if (current()?.runToken !== run.token) {
        run.abort.abort("lost");
        throw new Error("The sync was cancelled");
      }
    };
    return {
      step: (step) => update({ step }),
      loginRefused: () => {
        this.db.update(finBankLinks).set({ loginRefused: true }).where(linkKey).run();
      },
      challenging: () => {
        // Not when it was cancelled meanwhile: a challenge nobody answers counts.
        assertHeld();
        this.db
          .update(finBankLinks)
          .set({ unconfirmedTans: sql`${finBankLinks.unconfirmedTans} + 1` })
          .where(linkKey)
          .run();
      },
      challenge: (tan) => update({ status: "tan", step: "tan", tan: JSON.stringify(tan) }),
      waitForTan: async (ms) => {
        const until = Date.now() + ms;
        for (;;) {
          const row = current();
          if (row?.runToken !== run.token) {
            run.abort.abort("lost");
            throw new Error("The sync was cancelled");
          }
          if (row.tanInput) {
            update({ tanInput: null });
            return getSecretBox().open(row.tanInput);
          }
          if (Date.now() >= until) throw new BankError("The TAN wasn't entered in time");
          await sleep(this.tanPollMs, undefined, { signal });
        }
      },
      confirming: () => update({ status: "running", step: "tan", tan: null, tanInput: null }),
      confirmed: () => {
        this.db.update(finBankLinks).set({ unconfirmedTans: 0 }).where(linkKey).run();
      },
      saveSession: (session) => {
        this.db.update(finBankLinks).set({ session: sealSession(session) }).where(linkKey).run();
      },
    };
  }

  /** The first booking day to fetch: a while before the last one imported; on the first sync
   *  of an account with transactions (from CSV files, whose texts differ) the day after its
   *  latest; of an empty account, two years back. */
  private firstDay(link: LinkRow): string {
    if (link.syncedThrough) return addDays(link.syncedThrough, -RESYNC_DAYS);
    const latest = this.db
      .select({ day: sql<string | null>`max(${finTransactions.day})` })
      .from(finTransactions)
      .where(and(eq(finTransactions.familyId, link.familyId), eq(finTransactions.accountId, link.accountId)))
      .get()?.day;
    if (latest) return addDays(latest, 1);
    return addDays(localDay(this.now()), -FIRST_SYNC_DAYS);
  }

  /** Adds the bank's rows that aren't there yet to the account. */
  private async import(link: LinkRow, statement: BankStatement): Promise<SyncResult> {
    const store = new DrizzleFinanceStore(this.db);
    const now = this.now();
    const createdAt = now.toISOString();
    const rows: TransactionRow[] = statement.rows.map((r) => ({
      family_id: link.familyId,
      id: randomUUID(),
      day: r.day,
      amount_cents: r.amountCents,
      payee: r.payee,
      description: r.description,
      category_id: null,
      note: "",
      import_hash: null,
      account_id: link.accountId,
      transfer_id: null,
      split_of: null,
      created_at: createdAt,
    }));
    // A booking's own reference names it; rows without one count by their content, like a CSV row.
    const hashes: string[] = [];
    const unnamed = statement.rows.flatMap((r, i) => (r.reference ? [] : [i]));
    const byContent = await importHashes(unnamed.map((i) => rows[i]), link.accountId);
    let k = 0;
    for (const r of statement.rows) {
      hashes.push(
        r.reference ? await importHashOf(`bank|${link.provider}|${statement.accountRef}|${r.reference}`) : byContent[k++],
      );
    }
    const outcome = await importTransactions(store, link.familyId, rows, hashes, { autoTransfers: true });
    const last = statement.rows.reduce<string | null>((m, r) => (!m || r.day > m ? r.day : m), link.syncedThrough);
    this.db
      .update(finBankLinks)
      .set({ syncedThrough: last, lastSyncAt: now, updatedAt: now })
      .where(and(eq(finBankLinks.familyId, link.familyId), eq(finBankLinks.accountId, link.accountId)))
      .run();
    return {
      added: outcome.added,
      duplicates: outcome.duplicates.length,
      transfers: outcome.transfers,
      splits: outcome.splits,
      ids: outcome.ids,
    };
  }

  /** Waits for the running syncs until all ended or `ms` passed. */
  async idle(ms = Infinity): Promise<void> {
    const until = Date.now() + ms;
    while (this.done.size && Date.now() < until) {
      await Promise.race([
        Promise.allSettled([...this.done.values()]),
        new Promise((r) => setTimeout(r, Math.min(50, until - Date.now()))),
      ]);
    }
  }

  /** Stops: the running syncs end as interrupted (never run again: see above). */
  async stop(ms: number): Promise<void> {
    this.stopped = true;
    for (const run of this.running.values()) run.abort.abort("stop");
    await this.idle(ms);
  }
}

function heldBy(runToken: string | null) {
  return runToken === null ? sql`${finBankSyncs.runToken} is null` : eq(finBankSyncs.runToken, runToken);
}
