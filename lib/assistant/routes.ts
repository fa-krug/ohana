// The assistant's routes under /api/v1/families/{id}/ai (family-planner's _shared/ai.ts):
// settings (keys stored sealed, never returned), the endpoint's model list, a connection test,
// the chats (chat-routes.ts; their turns run in the worker, see runner.ts) and sorting
// transactions into categories. Settings, models, test and categorize are for editors; viewers
// see whether the assistant is set up, and chat with the tools that only read.
//
// Not ported: family-planner's POST /ai/chat (a turn of a chat the caller keeps, run in the
// request): Ohana's turns run in the worker only.

import type { Ctx, FamilyRoute } from "@/lib/api/family-api";
import { HttpError, json, NO_STORE, readBody } from "@/lib/api/http";
import { isValidDate } from "@/lib/calendar/dates";
import { DrizzleCalendarStore, type FamilyRow } from "@/lib/calendar/store";
import type { Db } from "@/lib/db";
import { getRole } from "@/lib/families/roles";
import { applyTransactionOps, benchmarkOf } from "@/lib/finance/finance";
import { DrizzleFinanceStore, type TransactionRow } from "@/lib/finance/store";
import { type SecretBox, getSecretBox } from "@/lib/secrets";
import { buildAgentDoc } from "./agent";
import { matchSimilar, type Search, suggestCategories } from "./categorize";
import { type ChatContext, systemPrompt } from "./chat";
import { handleChats } from "./chat-routes";
import type { ChatEnv, Turn } from "./chats";
import { DEFAULT_WINDOW } from "./context";
import { checkUrl, type NetOptions } from "./net";
import { contextWindow, listModels, type Provider, streamChat } from "./provider";
import { type AiSettingsRow, type AssistantStore, type ChatRow, DrizzleAssistantStore, SEARCH_PROVIDERS, type SearchProvider } from "./store";

export interface AiEnv extends ChatEnv {
  db: Db;
  /** Seals the stored keys (lib/secrets.ts); a function, as AUTH_SECRET is read at run time. */
  secrets: () => SecretBox;
  /** Requests to web pages and the search APIs: never to private addresses. */
  net: NetOptions;
  /** Requests to the family's AI endpoint: private addresses only with AI_ALLOW_PRIVATE_ENDPOINT
   *  (e.g. a model on the home network). */
  modelNet: NetOptions;
}

/** The app's AiEnv: the database, the app's SecretBox, the real network. */
export function defaultAiEnv(db: Db): AiEnv {
  const allowPrivate = /^(1|true|yes)$/i.test(process.env.AI_ALLOW_PRIVATE_ENDPOINT ?? "");
  return {
    db,
    store: new DrizzleAssistantStore(db),
    secrets: getSecretBox,
    net: { fetch: (...args) => fetch(...args) },
    modelNet: { fetch: (...args) => fetch(...args), allowPrivate },
  };
}

/** The context windows a family can set (tokens); 0 finds it out (or takes DEFAULT_WINDOW). */
const MIN_WINDOW = 1000;
const MAX_WINDOW = 10_000_000;

/** Transactions one categorize request sends to the model. */
const MAX_CATEGORIZE = 200;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function emptyRow(familyId: string): AiSettingsRow {
  return {
    family_id: familyId,
    base_url: "",
    model: "",
    api_key_enc: "",
    search_provider: "none",
    search_key_enc: "",
    allow_writes: true,
    context_window: 0,
    image_model: "",
    updated_at: new Date().toISOString(),
  };
}

const hint = (key: string) => (key ? key.slice(-4) : "");

function openKey(env: AiEnv, sealed: string): string {
  if (!sealed) return "";
  try {
    return env.secrets().open(sealed);
  } catch {
    throw new HttpError(503, "The stored key can't be read anymore (ENCRYPTION_KEY or AUTH_SECRET changed?) – enter it again");
  }
}

function safeOpen(env: AiEnv, sealed: string): string {
  try {
    return openKey(env, sealed);
  } catch {
    return "";
  }
}

/** The settings as the app gets them: no keys, only their last four characters. Viewers see
 *  whether the assistant is set up, and that they can only read. */
function publicSettings(env: AiEnv, row: AiSettingsRow, viewer = false) {
  const configured = !!(row.base_url && row.model);
  if (viewer) {
    return { configured, canEdit: false, model: row.model, allowWrites: false, serverReady: true };
  }
  return {
    configured,
    canEdit: true,
    baseUrl: row.base_url,
    model: row.model,
    hasKey: !!row.api_key_enc,
    keyHint: hint(safeOpen(env, row.api_key_enc)),
    searchProvider: row.search_provider,
    hasSearchKey: !!row.search_key_enc,
    searchKeyHint: hint(safeOpen(env, row.search_key_enc)),
    allowWrites: row.allow_writes,
    contextWindow: row.context_window ?? 0,
    // Ohana always has a key to seal with (ENCRYPTION_KEY, else derived from AUTH_SECRET).
    serverReady: true,
  };
}

async function loadRow(store: AssistantStore, familyId: string) {
  return (await store.getAiSettings(familyId)) ?? emptyRow(familyId);
}

async function cleanBaseUrl(v: unknown, env: AiEnv): Promise<string> {
  if (typeof v !== "string") throw new HttpError(400, "baseUrl must be a string");
  const s = v.trim().replace(/\/+$/, "");
  if (!s) return "";
  if (s.length > 500) throw new HttpError(400, "baseUrl is too long");
  return (await checkUrl(s, env.modelNet)).href.replace(/\/+$/, "");
}

function cleanKey(v: unknown, field: string): string {
  if (typeof v !== "string") throw new HttpError(400, `${field} must be a string`);
  const s = v.trim();
  if (s.length > 1000 || /\s/.test(s)) throw new HttpError(400, `${field} doesn't look like a key`);
  return s;
}

/** The route function for /families/{id}/ai/... (and /agent); null for anything else. */
export function handleAi(env: AiEnv): FamilyRoute {
  return (ctx) => {
    if (ctx.rest.length === 1 && ctx.rest[0] === "agent" && ctx.method === "GET") return agent(ctx);
    if (ctx.rest[0] !== "ai") return null;
    if (ctx.rest[1] === "chats") {
      return handleChats(ctx, env, async (familyId) => {
        const row = await env.store.getAiSettings(familyId);
        if (!row?.base_url || !row.model) throw new HttpError(400, "The AI assistant isn't set up yet");
      });
    }
    if (ctx.rest.length !== 2) return null;
    switch (`${ctx.method} ${ctx.rest[1]}`) {
      case "GET settings":
        return getSettings(ctx, env);
      case "PUT settings":
        return putSettings(ctx, env);
      case "POST models":
        return models(ctx, env);
      case "POST test":
        return test(ctx, env);
      case "POST categorize":
        return categorize(ctx, env);
    }
    return Promise.reject(new HttpError(404, "Not found"));
  };
}

async function getSettings({ load }: Ctx, env: AiEnv) {
  const { family, access } = await load("view");
  return json(publicSettings(env, await loadRow(env.store, family.id), access !== "edit"), 200, NO_STORE);
}

/** PUT /ai/settings {baseUrl, apiKey ("" removes it), model, searchProvider, searchKey,
 *  allowWrites, contextWindow (tokens, 0: from the endpoint)}: only the fields given change. */
async function putSettings({ req, load }: Ctx, env: AiEnv) {
  const { family } = await load("edit");
  const body = await readBody(req);
  const row = await loadRow(env.store, family.id);
  if (body.baseUrl !== undefined) row.base_url = await cleanBaseUrl(body.baseUrl, env);
  if (body.model !== undefined) {
    if (typeof body.model !== "string" || body.model.length > 200) {
      throw new HttpError(400, "model must be a string (max. 200)");
    }
    row.model = body.model.trim();
  }
  const seal = (v: unknown, field: string) => {
    const key = cleanKey(v, field);
    return key ? env.secrets().seal(key) : "";
  };
  if (body.apiKey !== undefined) row.api_key_enc = seal(body.apiKey, "apiKey");
  if (body.searchKey !== undefined) row.search_key_enc = seal(body.searchKey, "searchKey");
  if (body.searchProvider !== undefined) {
    if (!SEARCH_PROVIDERS.includes(body.searchProvider as SearchProvider)) {
      throw new HttpError(400, `searchProvider must be one of ${SEARCH_PROVIDERS.join(", ")}`);
    }
    row.search_provider = body.searchProvider as SearchProvider;
  }
  if (body.allowWrites !== undefined) {
    if (typeof body.allowWrites !== "boolean") throw new HttpError(400, "allowWrites must be true or false");
    row.allow_writes = body.allowWrites;
  }
  if (body.contextWindow !== undefined) {
    const n = body.contextWindow;
    if (typeof n !== "number" || !Number.isInteger(n) || (n !== 0 && (n < MIN_WINDOW || n > MAX_WINDOW))) {
      throw new HttpError(400, `contextWindow must be 0 (automatic) or ${MIN_WINDOW} to ${MAX_WINDOW} tokens`);
    }
    row.context_window = n;
  }
  row.updated_at = new Date().toISOString();
  await env.store.saveAiSettings(row);
  return json(publicSettings(env, row), 200, NO_STORE);
}

async function provider(row: AiSettingsRow, env: AiEnv, override: Record<string, unknown> = {}): Promise<Provider> {
  const baseUrl = override.baseUrl !== undefined ? await cleanBaseUrl(override.baseUrl, env) : row.base_url;
  if (!baseUrl) throw new HttpError(400, "Enter the URL of an OpenAI-compatible API first");
  const apiKey = override.apiKey ? cleanKey(override.apiKey, "apiKey") : openKey(env, row.api_key_enc);
  return { baseUrl, apiKey, model: row.model };
}

/** The web search the family set up, with its key; null without. */
function searchOf(row: AiSettingsRow, env: AiEnv): Search | null {
  return row.search_provider !== "none" && row.search_key_enc
    ? { provider: row.search_provider, key: openKey(env, row.search_key_enc) }
    : null;
}

/** POST /ai/models {baseUrl?, apiKey?}: the endpoint's models (the form can ask before saving). */
async function models({ req, load }: Ctx, env: AiEnv) {
  const { family } = await load("edit");
  const body = await readBody(req);
  const p = await provider(await loadRow(env.store, family.id), env, body);
  return json({ models: await listModels(p, env.modelNet) });
}

/** POST /ai/test: one short completion with the saved settings. */
async function test({ req, load }: Ctx, env: AiEnv) {
  const { family } = await load("edit");
  const row = await loadRow(env.store, family.id);
  const p = await provider(row, env);
  if (!p.model) throw new HttpError(400, "Pick a model first");
  let reply = "";
  const signal = AbortSignal.any([req.signal, AbortSignal.timeout(60_000)]);
  for await (const ev of streamChat(
    p,
    { messages: [{ role: "user", content: "Reply with the single word OK." }] },
    env.modelNet,
    signal,
  )) {
    if (ev.type === "done") reply = ev.content;
  }
  return json({ ok: true, model: p.model, reply: reply.trim().slice(0, 200) });
}

/** The tools' view of the family: its stores. */
function storesOf(env: AiEnv, familyId: string) {
  return {
    calendar: new DrizzleCalendarStore(env.db),
    finance: new DrizzleFinanceStore(env.db),
    db: env.db,
    familyId,
  };
}

/** A chat turn of the family (in the worker): its model, the instructions for the context, and
 *  the tools. Viewers (and families that switched changes off) get only the tools that read. */
export async function prepareTurn(
  env: AiEnv,
  chat: ChatRow,
  family: FamilyRow,
  context: ChatContext,
  signal?: AbortSignal,
): Promise<Turn> {
  const role = getRole(env.db, family.id, chat.user_id);
  if (!role) throw new HttpError(403, "You aren't a member of this family any more");
  const row = await loadRow(env.store, family.id);
  if (!row.base_url || !row.model) throw new HttpError(400, "The AI assistant isn't set up yet");
  const p = await provider(row, env);
  const search = searchOf(row, env);
  const stores = storesOf(env, family.id);
  const writes = row.allow_writes && role === "editor";
  const [types, categories, accounts, settings, window] = await Promise.all([
    stores.calendar.listTypes(family.id),
    stores.finance.listCategories(family.id),
    stores.finance.listAccounts(family.id),
    stores.finance.getFinanceSettings(family.id),
    row.context_window || contextWindow(p, env.modelNet),
  ]);
  const system = systemPrompt({
    family,
    types,
    categories,
    accounts,
    currency: settings?.currency ?? "EUR",
    benchmark: benchmarkOf(settings, categories),
    ...context,
    writes,
    readOnly: writes ? undefined : role === "editor" ? "settings" : "viewer",
    search: !!search,
  });
  return {
    provider: p,
    system,
    ctx: { ...stores, lang: context.lang, net: env.net, search, signal },
    modelNet: env.modelNet,
    writes,
    search: !!search,
    window: window || DEFAULT_WINDOW,
  };
}

/** POST /ai/categorize {ids?, from?, to?, skip?, lang?}: sorts uncategorized transactions (the
 *  given ones, or those in the range after the first `skip`, at most 200 per request) into
 *  categories: like similar earlier transactions where those agree (`matched`, no AI needed),
 *  the rest by the model, which may search the web for unknown payees. Without AI settings only
 *  the first step runs (`ai`: false). Returns `inverse` (ops for /finance/transactions that undo
 *  it) and `remaining`, the uncategorized rows in the range it didn't look at yet. The app
 *  waits for it (a batch of 200 at most, the web search limited to a minute). */
async function categorize({ req, load, finance }: Ctx, env: AiEnv) {
  const { family } = await load("edit");
  const body = await readBody(req);
  const row = await loadRow(env.store, family.id);
  const ai = !!(row.base_url && row.model);

  let candidates: TransactionRow[];
  let remaining = 0;
  if (body.ids !== undefined) {
    const ids = body.ids;
    if (!Array.isArray(ids) || ids.length > MAX_CATEGORIZE || ids.some((id) => typeof id !== "string" || !UUID_RE.test(id))) {
      throw new HttpError(400, `ids must be at most ${MAX_CATEGORIZE} transaction ids`);
    }
    candidates = (await finance.getTransactions(family.id, ids as string[])).filter((t) => !t.category_id);
  } else {
    const from = body.from ?? undefined,
      to = body.to ?? undefined;
    for (const d of [from, to]) {
      if (d !== undefined && !isValidDate(d)) throw new HttpError(400, "from/to must be YYYY-MM-DD");
    }
    const skip = body.skip ?? 0;
    if (!Number.isInteger(skip) || (skip as number) < 0) throw new HttpError(400, "skip must be a whole number");
    const open = (await finance.listTransactions(family.id, from as string, to as string))
      .filter((t) => !t.category_id)
      .slice(skip as number);
    candidates = open.slice(0, MAX_CATEGORIZE);
    remaining = open.length - candidates.length;
  }

  const [categories, all] = await Promise.all([
    finance.listCategories(family.id),
    candidates.length ? finance.listTransactions(family.id) : [],
  ]);
  const sorted = all.filter((t) => t.category_id);
  const similar = matchSimilar(candidates, sorted, categories);
  const rest = candidates.filter((t) => !similar.has(t.id));
  const byAi =
    ai && rest.length && categories.length
      ? await suggestCategories({
          provider: await provider(row, env),
          net: env.modelNet,
          categories,
          rows: rest,
          sorted,
          lang: body.lang === "de" ? "de" : "en",
          search: searchOf(row, env),
          tools: storesOf(env, family.id),
          signal: req.signal,
        })
      : new Map<string, string>();
  const assignments = [
    ...[...similar].map(([id, categoryId]) => ({ id, categoryId, source: "similar" })),
    ...[...byAi].map(([id, categoryId]) => ({ id, categoryId, source: "ai" })),
  ];
  const ops = assignments.map(({ id, categoryId }) => ({ action: "update", id, categoryId }));
  const { inverse } = ops.length ? await applyTransactionOps(finance, family.id, ops) : { inverse: [] };
  return json({ changed: ops.length, matched: similar.size, considered: candidates.length, remaining, ai, inverse, assignments });
}

/** GET /families/{id}/agent: instructions for AI agents that use the API with the user's
 *  token (Markdown), with the family's entry types and ready-to-use URLs. */
async function agent({ store, publicBase, loadWith }: Ctx): Promise<Response> {
  const [{ family, access }, types] = await loadWith("view", (id) => store.listTypes(id));
  const doc = buildAgentDoc({
    base: publicBase,
    readOnly: access !== "edit",
    family,
    types,
    today: new Date().toISOString().slice(0, 10),
    refreshSeconds: 15,
  });
  return new Response(doc, {
    headers: { ...NO_STORE, "access-control-allow-origin": "*", "content-type": "text/markdown; charset=utf-8" },
  });
}
