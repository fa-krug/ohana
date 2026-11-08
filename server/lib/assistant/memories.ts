// The assistant's memory: the family's standing instructions ("clothing from X goes into
// Kinderkleidung"), by module. The chat's instructions list them (chat.ts), the categorizer
// follows the finance ones (categorize.ts); the assistant keeps them with its tools remember /
// update_memory / forget (tools/memory.ts), the app lists and edits them.
//
// GET    /ai/memories[?module=]        {memories: [Memory]} (any member; modules on this server)
// POST   /ai/memories                  {id?, module, text} → 201 Memory (editors; id: one put back)
// PATCH  /ai/memories/{id}             {text?, module?} → Memory (editors)
// DELETE /ai/memories/{id}             {deleted: id} (editors)
//
// An agent token can't change them (lib/auth/token-scope.ts): instructions planted from outside
// would be followed in every chat.

import { randomUUID } from "node:crypto";
import { and, asc, eq, sql } from "drizzle-orm";
import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, NO_STORE, readBody } from "@/lib/api/http";
import type { Db } from "@/lib/db";
import { aiMemories, users } from "@/lib/db/schema";
import { moduleEnabled } from "@/lib/server-info";

/** The modules a memory can be about, in the order they're listed. */
export const MEMORY_MODULES = ["general", "calendar", "finance", "meals", "appointments", "chores", "knowledge"] as const;
export type MemoryModule = (typeof MEMORY_MODULES)[number];

export const MAX_MEMORY_TEXT = 300;
export const MAX_MEMORIES = 50;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface Memory {
  id: string;
  module: MemoryModule;
  text: string;
  createdAt: string;
  updatedAt: string;
  createdBy: { id: string; name: string } | null;
}

/** The modules on this server (general and the calendar always). */
export function memoryModules(env: Record<string, string | undefined> = process.env): MemoryModule[] {
  return MEMORY_MODULES.filter((m) => m === "general" || m === "calendar" || moduleEnabled(m, env));
}

/** A module memories can be kept for on this server; 400 for anything else. */
export function cleanModule(v: unknown): MemoryModule {
  const modules = memoryModules();
  if (typeof v !== "string" || !modules.includes(v as MemoryModule)) {
    throw new HttpError(400, `module must be one of ${modules.join(", ")}`);
  }
  return v as MemoryModule;
}

/** The text, trimmed: 1–300 characters. */
export function cleanText(v: unknown): string {
  const s = typeof v === "string" ? v.trim() : "";
  if (!s || s.length > MAX_MEMORY_TEXT) {
    throw new HttpError(400, `text must be 1 to ${MAX_MEMORY_TEXT} characters`);
  }
  return s;
}

type Row = typeof aiMemories.$inferSelect;

/** The family's memories with their creator, in the order the app lists them. */
function rowsOf(db: Db, familyId: string, id?: string) {
  return db
    .select({ m: aiMemories, name: users.name, email: users.email })
    .from(aiMemories)
    .leftJoin(users, eq(users.id, aiMemories.createdById))
    .where(id ? and(eq(aiMemories.familyId, familyId), eq(aiMemories.id, id)) : eq(aiMemories.familyId, familyId))
    .orderBy(asc(aiMemories.createdAt), asc(sql`${aiMemories}.rowid`))
    .all();
}

function dto({ m, name, email }: { m: Row; name: string | null; email: string | null }): Memory {
  return {
    id: m.id,
    module: m.module as MemoryModule,
    text: m.text,
    createdAt: m.createdAt.toISOString(),
    updatedAt: m.updatedAt.toISOString(),
    createdBy: m.createdById ? { id: m.createdById, name: name?.trim() || (email ?? "").split("@")[0] } : null,
  };
}

/** The family's memories of the modules on this server (or of one), by module (general,
 *  calendar, finance …), then oldest first. */
export function listMemories(db: Db, familyId: string, module?: MemoryModule): Memory[] {
  const modules = memoryModules();
  const order = (m: string) => MEMORY_MODULES.indexOf(m as MemoryModule);
  return rowsOf(db, familyId)
    .filter(({ m }) => modules.includes(m.module as MemoryModule) && (!module || m.module === module))
    .map(dto)
    .sort((a, b) => order(a.module) - order(b.module)); // stable: keeps the creation order
}

/** A memory of the family, as stored (any module); null when there's none. */
export function getMemoryRow(db: Db, familyId: string, id: string): Row | null {
  return db.select().from(aiMemories).where(and(eq(aiMemories.familyId, familyId), eq(aiMemories.id, id))).get() ?? null;
}

function getMemory(db: Db, familyId: string, id: string): Memory {
  const row = rowsOf(db, familyId, id)[0];
  if (!row) throw new HttpError(404, "Memory not found");
  return dto(row);
}

function assertRoom(db: Db, familyId: string, module: MemoryModule) {
  const n = db
    .select({ id: aiMemories.id })
    .from(aiMemories)
    .where(and(eq(aiMemories.familyId, familyId), eq(aiMemories.module, module)))
    .all().length;
  if (n >= MAX_MEMORIES) {
    throw new HttpError(400, `The ${module} memory is full (${MAX_MEMORIES}): change or remove one first`);
  }
}

/** A new memory; `id` (a UUID) puts one back under its id (409 when it's taken). */
export function createMemory(
  db: Db,
  familyId: string,
  input: Record<string, unknown>,
  createdById: string | null,
  now = new Date(),
): Memory {
  const module = cleanModule(input.module);
  const text = cleanText(input.text);
  let id: string = randomUUID();
  if (input.id !== undefined && input.id !== null) {
    if (typeof input.id !== "string" || !UUID_RE.test(input.id)) throw new HttpError(400, "id must be a UUID");
    id = input.id.toLowerCase();
    if (db.select({ id: aiMemories.id }).from(aiMemories).where(eq(aiMemories.id, id)).get()) {
      throw new HttpError(409, "There is a memory with this id already");
    }
  }
  return db.transaction(
    (tx) => {
      assertRoom(tx as unknown as Db, familyId, module);
      tx.insert(aiMemories).values({ id, familyId, module, text, createdById, createdAt: now, updatedAt: now }).run();
      return getMemory(tx as unknown as Db, familyId, id);
    },
    { behavior: "immediate" },
  );
}

/** Changes a memory's text and / or module (only those given); 404 for an unknown one. */
export function updateMemory(db: Db, familyId: string, id: string, input: Record<string, unknown>, now = new Date()): Memory {
  const text = input.text !== undefined ? cleanText(input.text) : undefined;
  const module = input.module !== undefined ? cleanModule(input.module) : undefined;
  return db.transaction(
    (tx) => {
      const row = getMemoryRow(tx as unknown as Db, familyId, id);
      if (!row) throw new HttpError(404, "Memory not found");
      if (module && module !== row.module) assertRoom(tx as unknown as Db, familyId, module);
      if (text !== undefined || module !== undefined) {
        tx.update(aiMemories)
          .set({ ...(text !== undefined ? { text } : {}), ...(module ? { module } : {}), updatedAt: now })
          .where(eq(aiMemories.id, id))
          .run();
      }
      return getMemory(tx as unknown as Db, familyId, id);
    },
    { behavior: "immediate" },
  );
}

/** Removes a memory; returns it as it was; 404 for an unknown one. */
export function deleteMemory(db: Db, familyId: string, id: string): Row {
  const row = getMemoryRow(db, familyId, id);
  if (!row) throw new HttpError(404, "Memory not found");
  db.delete(aiMemories).where(eq(aiMemories.id, id)).run();
  return row;
}

/** The memories the chat's instructions show, by module (modules on this server only). */
export function memoriesForPrompt(db: Db, familyId: string): { module: MemoryModule; items: { id: string; text: string }[] }[] {
  const out: { module: MemoryModule; items: { id: string; text: string }[] }[] = [];
  for (const m of listMemories(db, familyId)) {
    const group = out.at(-1)?.module === m.module ? out.at(-1)! : (out.push({ module: m.module, items: [] }), out.at(-1)!);
    group.items.push({ id: m.id, text: m.text });
  }
  return out;
}

/** /families/{id}/ai/memories[/{memoryId}]: rest[0] is "ai", rest[1] "memories". */
export function handleMemories(ctx: Ctx): Promise<Response> {
  const [, , id, ...more] = ctx.rest;
  if (more.length) return Promise.reject(new HttpError(404, "Not found"));
  if (id === undefined) {
    if (ctx.method === "GET") return listRoute(ctx);
    if (ctx.method === "POST") return createRoute(ctx);
  } else {
    if (ctx.method === "PATCH") return updateRoute(ctx, id);
    if (ctx.method === "DELETE") return deleteRoute(ctx, id);
  }
  return Promise.reject(new HttpError(405, "Method not allowed"));
}

async function listRoute(ctx: Ctx): Promise<Response> {
  const asked = ctx.url.searchParams.get("module");
  let module: MemoryModule | undefined;
  if (asked !== null && asked !== "") {
    if (!MEMORY_MODULES.includes(asked as MemoryModule)) {
      throw new HttpError(400, `module must be one of ${MEMORY_MODULES.join(", ")}`);
    }
    module = asked as MemoryModule;
  }
  const { family } = await ctx.load("view");
  return json({ memories: listMemories(ctx.db, family.id, module) }, 200, NO_STORE);
}

async function createRoute(ctx: Ctx): Promise<Response> {
  const { family } = await ctx.load("edit");
  const body = await readBody(ctx.req);
  return json(createMemory(ctx.db, family.id, body, ctx.principal?.id ?? null, ctx.now), 201, NO_STORE);
}

async function updateRoute(ctx: Ctx, id: string): Promise<Response> {
  const { family } = await ctx.load("edit");
  const body = await readBody(ctx.req);
  return json(updateMemory(ctx.db, family.id, id, body, ctx.now), 200, NO_STORE);
}

async function deleteRoute(ctx: Ctx, id: string): Promise<Response> {
  const { family } = await ctx.load("edit");
  deleteMemory(ctx.db, family.id, id);
  return json({ deleted: id });
}
