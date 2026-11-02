// Recipe imports in the background (the share extension hands a page over and closes): POST
// …/meals/recipes/import with `background: true` only saves a `recipe_imports` row; the
// worker's ImportRunner runs it with importRecipe (import.ts), exactly as the waiting import
// does. Done: the row is deleted (the app notices it's gone) and the starter's devices get a
// push; failed: the row says why (retry or delete it), and a push says so too.
//
// Claiming is a compare-and-swap UPDATE (status, run token) that takes a lease
// (`locked_until`), so no import runs twice; a worker that died leaves a running row whose lease
// runs out: it is run once more, then marked failed. A row deleted while it runs is noticed at
// the next tick (the run is aborted) and when it ends (a recipe saved meanwhile is deleted).

import { randomUUID } from "node:crypto";
import { and, asc, desc, eq, inArray, isNull, lte, or, sql } from "drizzle-orm";
import { HttpError, randomToken } from "@/lib/api/http";
import { type AiEnv, defaultAiEnv, familyModel } from "@/lib/assistant/routes";
import { getAppUrl } from "@/lib/auth/config";
import type { Db } from "@/lib/db";
import { recipeImports, recipes } from "@/lib/db/schema";
import { pickLocale } from "@/lib/i18n/locale";
import { removeRecipeImage } from "@/lib/meals/recipes/images";
import { deleteRecipe } from "@/lib/meals/recipes/mutations";
import { notifyFamily } from "@/lib/notifications";
import { translator } from "@/lib/notifications/locale";
import type { RelayClient } from "@/lib/push/relay";
import { moduleEnabled } from "@/lib/server-info";
import { type ImportRecipeInput, importRecipe, importRecipeSchema } from "./import";

/** How long one import may take. */
export const IMPORT_TIMEOUT_MS = 4 * 60_000;
/** The lease a running import holds (longer than it may take). */
export const IMPORT_LEASE_MS = 6 * 60_000;
/** Runs of one import before a lost one counts as failed. */
export const MAX_IMPORT_ATTEMPTS = 2;
/** Failed imports are kept this long. */
export const FAILED_IMPORT_KEEP_MS = 7 * 24 * 60 * 60_000;

const NO_AI = "The AI isn't set up yet (Settings → AI)";

export type ImportStatus = "waiting" | "running" | "failed";

/** What the app gets of an import. */
export interface RecipeImportDto {
  id: string;
  url: string;
  /** The page's title once known ("" before). */
  title: string;
  imageUrl: string | null;
  status: ImportStatus;
  error: string | null;
  createdAt: string;
}

type Row = typeof recipeImports.$inferSelect;

function dto(r: Row): RecipeImportDto {
  return {
    id: r.id,
    url: r.url,
    title: r.title,
    imageUrl: r.imageUrl,
    status: r.status as ImportStatus,
    error: r.error,
    createdAt: r.createdAt.toISOString(),
  };
}

function ownRow(db: Db, familyId: string, id: string): Row {
  const row = db
    .select()
    .from(recipeImports)
    .where(and(eq(recipeImports.id, id), eq(recipeImports.familyId, familyId)))
    .get();
  if (!row) throw new HttpError(404, "Import not found");
  return row;
}

/** Saves an import for the worker. */
export function enqueueImport(
  db: Db,
  familyId: string,
  userId: string,
  input: ImportRecipeInput,
  language: "en" | "de",
  now: Date,
): RecipeImportDto {
  // Whole seconds, as stored: the 202's createdAt is the list's.
  const at = new Date(Math.floor(now.getTime() / 1000) * 1000);
  const row: Row = {
    id: randomUUID(),
    familyId,
    userId,
    url: input.url,
    title: input.title,
    imageUrl: input.imageUrl,
    input: JSON.stringify(input),
    language,
    status: "waiting",
    error: null,
    attempts: 0,
    runToken: null,
    lockedUntil: null,
    createdAt: at,
    updatedAt: at,
  };
  db.insert(recipeImports).values(row).run();
  return dto(row);
}

/** The family's imports (waiting, running and failed), newest first. */
export function listImports(db: Db, familyId: string): RecipeImportDto[] {
  return db
    .select()
    .from(recipeImports)
    .where(eq(recipeImports.familyId, familyId))
    .orderBy(desc(recipeImports.createdAt), desc(sql`rowid`))
    .all()
    .map(dto);
}

/** Deletes an import in any state (a running one's result is discarded by its worker). */
export function deleteImport(db: Db, familyId: string, id: string): void {
  ownRow(db, familyId, id);
  db.delete(recipeImports).where(eq(recipeImports.id, id)).run();
}

/** Puts a failed import back in the queue; 409 for one that hasn't failed. */
export function retryImport(db: Db, familyId: string, id: string, now: Date): RecipeImportDto {
  const row = ownRow(db, familyId, id);
  if (row.status !== "failed") throw new HttpError(409, "Only a failed import can be retried");
  const set = { status: "waiting", error: null, attempts: 0, runToken: null, lockedUntil: null, updatedAt: now };
  db.update(recipeImports).set(set).where(and(eq(recipeImports.id, id), eq(recipeImports.status, "failed"))).run();
  return dto({ ...row, ...set });
}

/** Removes failed imports older than FAILED_IMPORT_KEEP_MS (cleanup). */
export function pruneFailedImports(db: Db, now: Date): number {
  return db
    .delete(recipeImports)
    .where(and(eq(recipeImports.status, "failed"), lte(recipeImports.updatedAt, new Date(now.getTime() - FAILED_IMPORT_KEEP_MS))))
    .run().changes;
}

/** The row as the claim read it still holds: same status and run token. */
function held(r: Row) {
  return and(
    eq(recipeImports.id, r.id),
    eq(recipeImports.status, r.status),
    r.runToken === null ? isNull(recipeImports.runToken) : eq(recipeImports.runToken, r.runToken),
  );
}

export interface ImportRunnerOptions {
  /** The AI and the network (tests: lib/test/assistant.ts's env). */
  env?: AiEnv;
  maxConcurrent?: number;
  /** Replaces the push relay client (tests). */
  push?: RelayClient;
  now?: () => Date;
  timeoutMs?: number;
  leaseMs?: number;
  log?: (msg: string) => void;
}

interface Running {
  abort: AbortController;
  token: string;
}

/** The worker's import loop: every tick one cheap indexed query finds the waiting imports (and
 *  running ones whose lease ran out), claims each and runs it WITHOUT awaiting, at most
 *  `maxConcurrent` at once. */
export class ImportRunner {
  private readonly running = new Map<string, Running>();
  private readonly done = new Map<string, Promise<void>>();
  private stopped = false;
  private readonly env: AiEnv;
  private readonly maxConcurrent: number;
  private readonly now: () => Date;
  private readonly timeoutMs: number;
  private readonly leaseMs: number;
  private readonly log: (msg: string) => void;

  constructor(
    private readonly db: Db,
    private readonly opts: ImportRunnerOptions = {},
  ) {
    this.env = opts.env ?? defaultAiEnv(db);
    this.maxConcurrent = opts.maxConcurrent ?? Math.max(1, Number(process.env.IMPORT_MAX_CONCURRENT) || 2);
    this.now = opts.now ?? (() => new Date());
    this.timeoutMs = opts.timeoutMs ?? IMPORT_TIMEOUT_MS;
    this.leaseMs = opts.leaseMs ?? IMPORT_LEASE_MS;
    this.log = opts.log ?? ((m) => console.log(`[imports] ${m}`));
  }

  get active(): number {
    return this.running.size;
  }

  /** Aborts the runs whose rows are gone, gives up on lost ones that ran too often, then claims
   *  and starts waiting ones; returns how many were started. Never throws. */
  tick(now = this.now()): number {
    if (this.stopped || !moduleEnabled("meals") || !moduleEnabled("assistant")) return 0;
    let started = 0;
    try {
      if (this.running.size) {
        const ids = [...this.running.keys()];
        const rows = this.db
          .select({ id: recipeImports.id, runToken: recipeImports.runToken })
          .from(recipeImports)
          .where(inArray(recipeImports.id, ids))
          .all();
        const tokens = new Map(rows.map((r) => [r.id, r.runToken]));
        for (const [id, run] of this.running) {
          if (tokens.get(id) !== run.token) run.abort.abort("lost");
        }
      }
      const due = this.db
        .select()
        .from(recipeImports)
        .where(
          or(
            eq(recipeImports.status, "waiting"),
            and(eq(recipeImports.status, "running"), lte(recipeImports.lockedUntil, now)),
          ),
        )
        .orderBy(asc(recipeImports.createdAt), asc(sql`rowid`))
        .all();
      for (const row of due) {
        if (this.running.has(row.id)) continue;
        if (row.status === "running" && row.attempts >= MAX_IMPORT_ATTEMPTS) {
          const key = `interrupted:${row.id}`;
          if (!this.done.has(key)) {
            this.done.set(key, this.interrupted(row, now).finally(() => this.done.delete(key)));
          }
          continue;
        }
        if (this.running.size >= this.maxConcurrent) continue;
        if (this.start(row, now)) started += 1;
      }
    } catch (err) {
      console.error("[imports] tick failed:", err);
    }
    return started;
  }

  private start(row: Row, now: Date): boolean {
    const token = randomToken(32);
    const claimed = this.db
      .update(recipeImports)
      .set({
        status: "running",
        runToken: token,
        lockedUntil: new Date(now.getTime() + this.leaseMs),
        attempts: row.attempts + 1,
        updatedAt: now,
      })
      .where(held(row))
      .run().changes === 1;
    if (!claimed) return false;
    if (row.status === "running") this.log(`running import ${row.id} again (its worker went away)`);
    const run: Running = { abort: new AbortController(), token };
    this.running.set(row.id, run);
    const p = this.run(row, run)
      .catch((err) => console.error(`[imports] import ${row.id} failed:`, err))
      .finally(() => {
        this.running.delete(row.id);
        this.done.delete(row.id);
        // More may wait: the next one starts without waiting for the tick.
        this.tick();
      });
    this.done.set(row.id, p);
    return true;
  }

  private async run(row: Row, run: Running): Promise<void> {
    const timeout = AbortSignal.timeout(this.timeoutMs);
    const signal = AbortSignal.any([run.abort.signal, timeout]);
    const mine = and(eq(recipeImports.id, row.id), eq(recipeImports.runToken, run.token));
    let result: { id: string; title: string };
    try {
      const input = importRecipeSchema.parse(JSON.parse(row.input));
      const model = await familyModel(this.env, row.familyId);
      if (!model) throw new HttpError(400, NO_AI);
      result = await importRecipe({
        db: this.db,
        familyId: row.familyId,
        input,
        language: row.language === "de" ? "de" : "en",
        provider: model.provider,
        modelNet: this.env.modelNet,
        net: this.env.net,
        now: this.now(),
        signal,
        onPage: (page) => {
          // The placeholder shows the page's title and photo while the model reads.
          const title = page.recipeName || page.title;
          const set = {
            ...(!row.title && title ? { title } : {}),
            ...(!row.imageUrl && page.imageUrl ? { imageUrl: page.imageUrl } : {}),
          };
          if (Object.keys(set).length) this.db.update(recipeImports).set(set).where(mine).run();
        },
      });
    } catch (err) {
      if (run.abort.signal.aborted) {
        // Deleted meanwhile: nothing to tell. The worker stops: the next one takes it over.
        if (this.stopped) this.release(row, run);
        return;
      }
      const message = timeout.aborted
        ? "The import took too long"
        : err instanceof HttpError
          ? err.message
          : "The import failed";
      if (!(err instanceof HttpError) && !timeout.aborted) console.error(`[imports] import ${row.id} failed:`, err);
      const failed = this.db
        .update(recipeImports)
        .set({ status: "failed", error: message, runToken: null, lockedUntil: null, updatedAt: this.now() })
        .where(mine)
        .run().changes === 1;
      if (failed) await this.notifyFailed(row, message);
      return;
    }
    const finished = this.db.delete(recipeImports).where(mine).run().changes === 1;
    if (!finished) {
      // Deleted (or taken over) while the model read: the recipe nobody waits for goes again.
      this.log(`import ${row.id} was dropped, deleting recipe ${result.id}`);
      this.discard(row.familyId, result.id);
      return;
    }
    await this.notifyDone(row, result);
  }

  private discard(familyId: string, recipeId: string): void {
    try {
      if (!this.db.select({ id: recipes.id }).from(recipes).where(eq(recipes.id, recipeId)).get()) return;
      removeRecipeImage(this.db, familyId, recipeId);
      deleteRecipe(this.db, familyId, recipeId);
    } catch (err) {
      console.error(`[imports] deleting recipe ${recipeId} failed:`, err);
    }
  }

  /** Back to waiting, as if this worker had never claimed it. */
  private release(row: Row, run: Running): void {
    this.db
      .update(recipeImports)
      .set({ status: "waiting", runToken: null, lockedUntil: null, attempts: row.attempts })
      .where(and(eq(recipeImports.id, row.id), eq(recipeImports.runToken, run.token)))
      .run();
  }

  /** A lost run that ran too often: failed. */
  private async interrupted(row: Row, now: Date): Promise<void> {
    const message = "The import was interrupted";
    const failed = this.db
      .update(recipeImports)
      .set({ status: "failed", error: message, runToken: null, lockedUntil: null, updatedAt: now })
      .where(held(row))
      .run().changes === 1;
    if (failed) await this.notifyFailed(row, message);
  }

  private async notifyDone(row: Row, recipe: { id: string; title: string }): Promise<void> {
    if (!row.userId) return;
    const t = translator(pickLocale([row.language]));
    await this.notify(row, {
      title: recipe.title,
      body: t("notifications.recipeImport.saved"),
      url: `${getAppUrl()}/f/${row.familyId}/meals/recipes/${recipe.id}`,
      collapseKey: `recipe-import:${row.id}`,
    });
  }

  private async notifyFailed(row: Row, error: string): Promise<void> {
    if (!row.userId) return;
    const t = translator(pickLocale([row.language]));
    let host = "";
    try {
      host = new URL(row.url).hostname;
    } catch {
      // stays ""
    }
    await this.notify(row, {
      title: t("notifications.recipeImport.failed"),
      body: host ? `${error} · ${host}` : error,
      url: `${getAppUrl()}/f/${row.familyId}/meals/recipes`,
      collapseKey: `recipe-import:${row.id}`,
    });
  }

  private async notify(row: Row, message: { title: string; body: string; url: string; collapseKey: string }) {
    try {
      await notifyFamily(this.db, row.familyId, message, {
        channelIds: [],
        app: { userIds: [row.userId!] },
        event: "recipe_imported",
        push: this.opts.push,
      });
    } catch (err) {
      console.error(`[imports] notification of import ${row.id} failed:`, err);
    }
  }

  /** Waits for the running imports until all ended or `ms` passed. */
  async idle(ms = Infinity): Promise<void> {
    const until = Date.now() + ms;
    while (this.done.size && Date.now() < until) {
      await Promise.race([
        Promise.allSettled([...this.done.values()]),
        new Promise((r) => setTimeout(r, Math.min(50, until - Date.now()))),
      ]);
    }
  }

  /** Stops: the runs end where they are and their imports wait again for the next worker. */
  async stop(ms: number): Promise<void> {
    this.stopped = true;
    for (const run of this.running.values()) run.abort.abort("stop");
    await this.idle(ms);
  }
}
