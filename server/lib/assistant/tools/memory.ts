// The assistant's tool for its memory, the family's standing instructions by module
// (lib/assistant/memories.ts). The chat's instructions list the memories already, so there's no
// tool to read them. edit_memories works like suggest_items (suggestions.ts): it checks its ops
// against the stored memories and writes nothing, then ends the step: the chat shows the changes
// as a card (`kind: "memories"`), the user ticks the ones to keep, the app applies them through
// the family API (POST / PATCH / DELETE /ai/memories) and answers (POST
// /ai/chats/{id}/memories); that answer is the tool's result. Of no module: memories of any
// module on this server.

import { HttpError } from "@/lib/api/http";
import {
  cleanModule,
  cleanText,
  listMemories,
  MAX_MEMORIES,
  MAX_MEMORY_TEXT,
  type Memory,
  type MemoryModule,
  memoryModules,
} from "../memories";
import type { Tool, ToolContext } from "./common";

/** One change of the memory, resolved: `id` the stored memory's (update, remove); `module` and
 *  `text` what it is afterwards (remove: what it was); `old` what is stored now (update, remove). */
export interface MemoryOp {
  action: "add" | "update" | "remove";
  id?: string;
  module: MemoryModule;
  text: string;
  old?: { module: MemoryModule; text: string };
}

/** Changes of the memory waiting for the user to confirm them in the app. */
export interface MemoriesEdit {
  summary: string;
  ops: MemoryOp[];
}

export const MAX_MEMORY_OPS = 20;

const fold = (s: string) => s.toLocaleLowerCase().replace(/\s+/g, " ");

/** The ops checked against the stored memories (modules on this server only). */
export function resolveMemoryOps(ctx: ToolContext, raw: unknown): MemoryOp[] {
  if (!Array.isArray(raw) || !raw.length) throw new HttpError(400, "ops must be a list of changes");
  if (raw.length > MAX_MEMORY_OPS) throw new HttpError(400, `At most ${MAX_MEMORY_OPS} changes at a time`);
  const stored = listMemories(ctx.db, ctx.familyId);
  const byId = new Map(stored.map((m) => [m.id, m]));
  const touched = new Set<string>();
  const ops = raw.map((o, i): MemoryOp => {
    try {
      if (!o || typeof o !== "object") throw new HttpError(400, "must be an object");
      const a = o as Record<string, unknown>;
      if (a.action === "add") return { action: "add", module: cleanModule(a.module), text: cleanText(a.text) };
      if (a.action !== "update" && a.action !== "remove") throw new HttpError(400, 'action must be "add", "update" or "remove"');
      const id = typeof a.id === "string" ? a.id : "";
      const m: Memory | undefined = byId.get(id);
      if (!m) throw new HttpError(404, `No memory "${id}"`);
      if (touched.has(id)) throw new HttpError(400, `memory "${id}" is changed twice`);
      touched.add(id);
      const old = { module: m.module, text: m.text };
      if (a.action === "remove") return { action: "remove", id, module: m.module, text: m.text, old };
      const text = a.text !== undefined && a.text !== null ? cleanText(a.text) : undefined;
      const module = a.module !== undefined && a.module !== null ? cleanModule(a.module) : undefined;
      if (text === undefined && module === undefined) throw new HttpError(400, "give a new text or module");
      return { action: "update", id, module: module ?? m.module, text: text ?? m.text, old };
    } catch (err) {
      if (err instanceof HttpError) throw new HttpError(err.status, `ops[${i}]: ${err.message}`);
      throw err;
    }
  });
  // No duplicates: a memory added or changed mustn't say what another one says afterwards.
  const after = new Map(stored.map((m) => [m.id, { module: m.module, text: m.text }]));
  const changed = new Set<string>();
  ops.forEach((op, i) => {
    if (op.action === "remove") return void after.delete(op.id!);
    const key = op.id ?? `new:${i}`;
    after.set(key, { module: op.module, text: op.text });
    changed.add(key);
  });
  for (const key of changed) {
    const m = after.get(key)!;
    const same = [...after].find(([id, o]) => id !== key && o.module === m.module && fold(o.text) === fold(m.text));
    if (!same) continue;
    if (!same[0].startsWith("new:") && !changed.has(same[0])) {
      throw new HttpError(409, `This is remembered already (${same[0]}): update that one instead`);
    }
    throw new HttpError(400, "The same memory is in the changes twice");
  }
  for (const module of memoryModules()) {
    const n = [...after.values()].filter((m) => m.module === module).length;
    if (n > MAX_MEMORIES) {
      throw new HttpError(400, `The ${module} memory would be too full (at most ${MAX_MEMORIES}): change or remove one instead`);
    }
  }
  return ops;
}

/** Long texts shortened for the card's summary. */
const short = (t: string) => (t.length > 60 ? `${t.slice(0, 59)}…` : t);

/** What the card says: one change by its text ("Remember “…”"), several by counts. */
export function memoriesSummary(ops: MemoryOp[], lang: "en" | "de"): string {
  const de = lang === "de";
  if (ops.length === 1) {
    const t = short(ops[0].text);
    const one = de
      ? { add: `Merken: „${t}“`, update: `Gemerktes ändern: „${t}“`, remove: `Vergessen: „${t}“` }
      : { add: `Remember “${t}”`, update: `Change the memory “${t}”`, remove: `Forget “${t}”` };
    return one[ops[0].action];
  }
  const words = de
    ? { add: "neu", update: "geändert", remove: "vergessen" }
    : { add: "new", update: "changed", remove: "forgotten" };
  const parts = (["add", "update", "remove"] as const)
    .map((a) => [ops.filter((o) => o.action === a).length, words[a]] as const)
    .filter(([n]) => n)
    .map(([n, w]) => `${n} ${w}`);
  return `${de ? "Gedächtnis" : "Memory"}: ${parts.join(", ")}`;
}

export const memoryTools: Record<string, Tool> = {
  edit_memories: {
    write: true,
    get spec() {
      return {
        name: "edit_memories",
        description:
          'Offers changes of the family\'s memory (see Memory): add, update (id; text and / or module) or remove (id). Nothing changes until the user confirms them on a card. Result: {"applied": true, "results": [{"op", "title", "ok", "declined"?, "error"?}]}, {"applied": false} or {"skipped": true}. Call it last in the step.',
        parameters: {
          type: "object",
          properties: {
            ops: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  action: { type: "string", enum: ["add", "update", "remove"] },
                  id: { type: "string" },
                  module: { type: "string", enum: memoryModules() },
                  text: { type: "string", description: `One short sentence (≤ ${MAX_MEMORY_TEXT} characters)` },
                },
                required: ["action"],
              },
            },
          },
          required: ["ops"],
        },
      };
    },
    run(args, ctx) {
      const ops = resolveMemoryOps(ctx, args.ops);
      const summary = memoriesSummary(ops, ctx.lang);
      return Promise.resolve({ result: { waiting: true }, summary, memories: { summary, ops } });
    },
  },
};
