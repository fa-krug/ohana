// family-planner: the assistant (ai_settings, ai_chats, ai_chat_items, ai_chat_messages).
//
// AI settings: the API and search keys are sealed with family-planner's AI_CONFIG_KEY (its
// SecretBox, the same "v1:" format as lib/secrets.ts). With that key
// (`--family-planner-ai-secret`) they are opened and sealed again with Ohana's; without it, or
// when a key doesn't open, the settings come over without it and the report lists the family
// under "AI keys to enter again".
//
// Chats keep their ids, items, messages and revisions (times in milliseconds). Nothing runs in
// them at import time: a chat that was running comes over as a turn that waits for the worker
// with a stop asked (`stop`, no holder), so the worker ends it the way a stop does (tools that
// ran marked interrupted, "(stopped)" for the model) without calling the model; messages that
// waited in a chat's queue are dropped (they would start turns long after they were written).
// Both are reported.
import { aiSettings, chatItems, chatMessages, chats, families } from "@/lib/db/schema";
import { SEARCH_PROVIDERS, type SearchProvider } from "@/lib/assistant/store";
import { eq } from "drizzle-orm";
import { pgBool, pgDate, pgInt, type PgRow } from "../pgdump";
import type { ImportContext } from "../types";
import { fpRows } from "./source";

/** A jsonb value as compact JSON text, or `fallback` when it is missing or isn't `valid`. */
function json(v: string | null | undefined, valid: (x: unknown) => boolean, fallback: string | null): string | null {
  if (!v) return fallback;
  try {
    const parsed: unknown = JSON.parse(v);
    return valid(parsed) ? JSON.stringify(parsed) : fallback;
  } catch {
    return fallback;
  }
}

const isObject = (x: unknown) => typeof x === "object" && x !== null && !Array.isArray(x);

function familyName(ctx: ImportContext, familyId: string): string {
  return ctx.db.select({ name: families.name }).from(families).where(eq(families.id, familyId)).get()?.name ?? familyId;
}

export function importFamilyPlannerAiSettings(ctx: ImportContext): void {
  const src = ctx.sources.familyPlanner;
  if (!src) return;
  const old = ctx.familyPlannerSecrets;
  let sealed = 0;
  let opened = 0;

  for (const s of fpRows(src, "ai_settings")) {
    const familyId = ctx.familyIds.familyPlanner.get(s.family_id ?? "");
    if (!familyId) {
      ctx.skip("familyPlanner", "ai_settings", s.family_id ?? "", "its family isn't imported");
      continue;
    }
    const lost: string[] = [];
    const reseal = (value: string | null, what: string): string => {
      if (!value) return "";
      sealed++;
      if (!old) {
        lost.push(what);
        return "";
      }
      try {
        const plain = old.open(value);
        opened++;
        return ctx.secrets.seal(plain);
      } catch {
        lost.push(what);
        return "";
      }
    };
    const provider = SEARCH_PROVIDERS.includes(s.search_provider as SearchProvider) ? (s.search_provider as SearchProvider) : "none";
    ctx.db
      .insert(aiSettings)
      .values({
        familyId,
        baseUrl: s.base_url ?? "",
        model: s.model ?? "",
        apiKeyEnc: reseal(s.api_key_enc, "API key"),
        searchProvider: provider,
        searchKeyEnc: reseal(s.search_key_enc, "search key"),
        allowWrites: s.allow_writes === undefined || s.allow_writes === null ? true : pgBool(s.allow_writes),
        contextWindow: Math.max(0, pgInt(s.context_window)),
        imageModel: "",
        updatedAt: pgDate(s.updated_at) ?? ctx.now,
      })
      .run();
    if (lost.length > 0) {
      ctx.report.aiKeys.push({
        familyId,
        family: familyName(ctx, familyId),
        keys: lost,
        reason: old ? "didn't open with the given --family-planner-ai-secret" : "no --family-planner-ai-secret given",
      });
    }
  }
  if (old && sealed > 0 && opened === 0) {
    ctx.note(
      "None of family-planner's AI keys opened with --family-planner-ai-secret: is it family-planner's AI_CONFIG_KEY?",
    );
  }
}

/** Chats with their items and messages; chats whose family or user isn't imported are skipped. */
export function importFamilyPlannerChats(ctx: ImportContext): void {
  const src = ctx.sources.familyPlanner;
  if (!src) return;
  const items = groupBy(fpRows(src, "ai_chat_items"));
  const messages = groupBy(fpRows(src, "ai_chat_messages"));

  for (const c of fpRows(src, "ai_chats")) {
    const id = c.id ?? "";
    const familyId = ctx.familyIds.familyPlanner.get(c.family_id ?? "");
    const userId = ctx.userIds.familyPlanner.get(c.user_id ?? "");
    if (!familyId || !userId) {
      ctx.skip("familyPlanner", "ai_chats", `${id} "${c.title ?? ""}"`, !familyId ? "its family isn't imported" : "its user isn't imported");
      continue;
    }
    const running = c.status === "running";
    const queue = json(c.queue, Array.isArray, "[]")!;
    const queued = (JSON.parse(queue) as unknown[]).length;
    const label = `chat "${c.title ?? ""}" (${id}) in family ${familyName(ctx, familyId)}`;
    if (running) ctx.note(`family-planner ${label} was running: its turn is ended as stopped by the worker (no model call)`);
    if (queued > 0) ctx.note(`family-planner ${label}: ${queued} waiting message(s) dropped`);

    const createdAt = pgDate(c.created_at) ?? ctx.now;
    ctx.db
      .insert(chats)
      .values({
        id,
        familyId,
        userId,
        title: c.title ?? "",
        // A running turn waits for the worker (no holder), with a stop asked.
        status: running ? "running" : "idle",
        runToken: null,
        runUntil: null,
        stop: running,
        retries: 0,
        context: json(c.context, isObject, "{}")!,
        activity: null,
        notes: json(c.notes, Array.isArray, "[]")!,
        usage: json(c.usage, isObject, null),
        queue: "[]",
        rev: pgInt(c.rev),
        createdAt,
        updatedAt: pgDate(c.updated_at) ?? createdAt,
      })
      .run();

    for (const r of items.get(id) ?? []) {
      const item = json(r.item, isObject, null);
      if (item === null) {
        ctx.skip("familyPlanner", "ai_chat_items", `${id}/${r.seq}`, "not a JSON object");
        continue;
      }
      ctx.db.insert(chatItems).values({ chatId: id, seq: pgInt(r.seq), rev: pgInt(r.rev), item }).run();
    }
    for (const r of messages.get(id) ?? []) {
      const message = json(r.message, isObject, null);
      if (message === null) {
        ctx.skip("familyPlanner", "ai_chat_messages", `${id}/${r.seq}`, "not a JSON object");
        continue;
      }
      ctx.db.insert(chatMessages).values({ chatId: id, seq: pgInt(r.seq), message }).run();
    }
  }

  // Items and messages of chats that aren't there (family-planner's foreign keys make that
  // unlikely; those of skipped chats are covered by the chat's entry).
  const known = new Set(fpRows(src, "ai_chats").map((c) => c.id ?? ""));
  for (const [table, groups] of [["ai_chat_items", items], ["ai_chat_messages", messages]] as const) {
    for (const [chatId, rows] of groups) {
      if (!known.has(chatId)) ctx.skip("familyPlanner", table, `${chatId} (${rows.length})`, "its chat doesn't exist");
    }
  }
}

function groupBy(rows: PgRow[]): Map<string, PgRow[]> {
  const out = new Map<string, PgRow[]>();
  for (const r of rows) {
    const id = r.chat_id ?? "";
    out.set(id, [...(out.get(id) ?? []), r]);
  }
  return out;
}
