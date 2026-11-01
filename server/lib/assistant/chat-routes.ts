// The chat routes under /api/v1/families/{id}/ai/chats (family-planner's ai/chats.ts, web
// part). They only save what the user sends and mark the chat as running: the worker runs the
// turn (runner.ts). Followers read the chat from the database.
//
//   GET                    the user's chats
//   POST                   a new chat with its first message (streams, like the ones below)
//   GET    {chat}          the chat with its items
//   DELETE {chat}
//   GET    {chat}/events?since=rev   follows the chat: the items changed since `rev`, then
//                          "end" once no turn runs (or "reconnect": ask again)
//   POST   {chat}/messages a message; streams the answer like events
//   POST   {chat}/queue    a message while a turn runs: it goes next (or now, if none runs)
//   POST   {chat}/unqueue  takes back a message that waits
//   POST   {chat}/answer   the answer to the assistant's question; streams like events
//   POST   {chat}/reminders  the user applied (with the results) or declined the waiting
//                          Reminders edit; streams like events
//   POST   {chat}/stop     stops the running turn
//   POST   {chat}/undone   a change of the chat was undone (the model hears it next time)
//   POST   {chat}/page     moves the chat to another page
//   POST   import          a chat kept elsewhere (family-planner's device chats)
//
// Viewers chat too; their turns only get the tools that read (see routes.ts).

import type { Ctx } from "@/lib/api/family-api";
import { CORS, HttpError, json, NO_STORE, objectOf, randomToken, readBody } from "@/lib/api/http";
import {
  type ChatContext,
  cleanContext,
  cleanMessage,
  cleanPage,
  cleanParts,
  type Emit,
  sseResponse,
  windowHistory,
} from "./chat";
import {
  type Attachment,
  type ChatEnv,
  type Item,
  leaseUntil,
  onPage,
  openQuestion,
  openRemindersEdit,
  pause,
  type Queued,
  type ReminderResult,
  STOPPED,
  type Summary,
  summaryOf,
  type UserItem,
  withMessage,
} from "./chats";
import type { StoredMessage } from "./context";
import type { ChatMessage, ContentPart } from "./provider";
import type { ReminderOp } from "./tools";
import type { AssistantStore, ChatRow } from "./store";

/** How often followers look for news (the worker saves streaming text every 0.5 s). */
const POLL_MS = 500;
/** How often a follower marks the chat as looked at. */
const SEEN_MS = 15_000;
/** A follower's stream ends after this; the app asks again. */
const STREAM_MS = 100_000;
/** Chats per user and family; the oldest go. */
const MAX_CHATS = 100;
const MAX_TITLE = 60;
const MAX_TEXT = 20_000;
const MAX_ATTACHMENTS = 4;
/** Messages that can wait in a chat at once. */
const MAX_QUEUE = 10;
/** Imported chats: items and messages kept (the newest). */
const MAX_IMPORT_ITEMS = 1000;
const MAX_IMPORT_MESSAGES = 400;
const IMAGE_URL = /^data:image\/(png|jpeg|webp|gif);base64,[A-Za-z0-9+/=]+$/;

const streamHeaders = { ...CORS, ...NO_STORE };

/** Routes /families/{id}/ai/chats/...; `checkSetUp` throws unless the family's AI is set up. */
export function handleChats(
  ctx: Ctx,
  env: ChatEnv,
  checkSetUp: (familyId: string) => Promise<void>,
): Promise<Response> {
  const [id, action, ...more] = ctx.rest.slice(2);
  const target = id === undefined ? "" : id === "import" ? "import" : ":id";
  const route = `${ctx.method} ${target}${action === undefined ? "" : `/${action}`}`;
  if (more.length) return Promise.reject(new HttpError(404, "Not found"));
  const r = new ChatRoutes(ctx, env, checkSetUp);
  switch (route) {
    case "GET ":
      return r.list();
    case "POST ":
      return r.send(null);
    case "POST import":
      return r.importChat();
    case "GET :id":
      return r.get(id);
    case "DELETE :id":
      return r.remove(id);
    case "GET :id/events":
      return r.events(id);
    case "POST :id/messages":
      return r.send(id);
    case "POST :id/queue":
      return r.queue(id);
    case "POST :id/unqueue":
      return r.unqueue(id);
    case "POST :id/answer":
      return r.answer(id);
    case "POST :id/reminders":
      return r.reminders(id);
    case "POST :id/stop":
      return r.stop(id);
    case "POST :id/undone":
      return r.undone(id);
    case "POST :id/page":
      return r.move(id);
  }
  return Promise.reject(new HttpError(404, "Not found"));
}

/** Streams a chat from the database: the items changed since revision `since`, until no turn
 *  runs ("end") or the stream is long enough ("reconnect"). Messages that wait in an idle chat
 *  are about to start a turn (the worker takes them), so the stream waits for it. */
export async function follow(
  env: ChatEnv,
  id: string,
  since: number,
  emit: Emit,
  gone: AbortSignal,
) {
  const store = env.store;
  const until = Date.now() + (env.streamMs ?? STREAM_MS);
  let shown = "";
  // The user is looking (no "turn finished" notification); written every SEEN_MS at most.
  let seen = 0;
  const show = (s: Summary) => {
    const text = JSON.stringify(s);
    if (text !== shown) emit("chat", s);
    shown = text;
  };
  while (!gone.aborted) {
    const chat = await store.getChat(id);
    if (!chat) return emit("end", { deleted: true });
    if (chat.rev > since) {
      const rows = await store.listChatItems(id, since);
      emit("items", { rev: chat.rev, items: rows.map(({ seq, item }) => ({ seq, item })) });
      since = chat.rev;
    }
    show(summaryOf(chat));
    if (Date.now() - seen >= SEEN_MS) {
      seen = Date.now();
      await store.markChatSeen?.(id, new Date(seen));
    }
    if (chat.status !== "running" && !chat.queue.length) return emit("end", {});
    if (Date.now() >= until) return emit("reconnect", {});
    await pause(env.pollMs ?? POLL_MS, gone);
  }
}

class ChatRoutes {
  private store: AssistantStore;

  constructor(
    private ctx: Ctx,
    private env: ChatEnv,
    private checkSetUp: (familyId: string) => Promise<void>,
  ) {
    this.store = env.store;
  }

  /** The user's chat in the family. */
  private async ownChat(id: string) {
    const { family } = await this.ctx.load("view");
    const user = this.ctx.requireUser();
    const chat = await this.store.getChat(id);
    if (!chat || chat.family_id !== family.id || chat.user_id !== user.id) {
      throw new HttpError(404, "Chat not found");
    }
    return { family, user, chat };
  }

  async list() {
    const { family } = await this.ctx.load("view");
    const chats = await this.store.listChats(family.id, this.ctx.requireUser().id);
    return json({ chats: chats.map(summaryOf) }, 200, NO_STORE);
  }

  async get(id: string) {
    const { chat } = await this.ownChat(id);
    const rows = await this.store.listChatItems(id);
    return json({ chat: summaryOf(chat), rev: chat.rev, items: rows.map((r) => r.item) }, 200, NO_STORE);
  }

  async remove(id: string) {
    await this.ownChat(id);
    // A turn running in the worker notices that the chat is gone and ends.
    await this.store.deleteChat(id);
    return json({ ok: true });
  }

  async events(id: string) {
    await this.ownChat(id);
    const since = Number(this.ctx.url.searchParams.get("since") ?? 0);
    return sseResponse(
      (emit, gone) => follow(this.env, id, Number.isFinite(since) ? since : 0, emit, gone),
      streamHeaders,
    );
  }

  /** Hands a chat claimed for `token` on to the worker: still running, held by nobody. */
  private async release(id: string, token: string) {
    return this.store.updateChat(id, { run_token: null, run_until: null }, token);
  }

  /** Lets go of a chat claimed for `token` after a failed request: no turn runs. */
  private async letGo(id: string, token: string) {
    await this.store.updateChat(id, { status: "idle", run_token: null, run_until: null }, token).catch(() => {});
  }

  /** Starts a turn on a chat that is claimed for `token`: saves the new messages and items and
   *  hands the chat to the worker, then streams it. If saving fails, the chat is let go again. */
  private async begin(
    chat: ChatRow,
    token: string,
    add: { messages: ChatMessage[]; items: { seq: number; item: Item }[]; context: ChatContext },
  ) {
    const store = this.store;
    let rev: number | null;
    let row: ChatRow | null;
    try {
      const messages = await store.listChatMessages(chat.id);
      await store.addChatMessages(
        chat.id,
        add.messages.map((m, i) => ({ seq: messages.length + i, message: m as unknown as Record<string, unknown> })),
      );
      rev = await store.putChatItems(
        chat.id,
        add.items.map(({ seq, item }) => ({ seq, item: item as unknown as Record<string, unknown> })),
      );
      row = await store.updateChat(chat.id, { context: { ...add.context }, notes: [] }, token);
      if (rev === null || !row) throw new HttpError(404, "Chat not found");
      row = await this.release(chat.id, token);
      if (!row) throw new HttpError(404, "Chat not found");
    } catch (err) {
      await this.letGo(chat.id, token);
      throw err;
    }
    const summary = summaryOf(row);
    const since = rev;
    const env = this.env;
    return sseResponse(async (emit, gone) => {
      emit("chat", summary);
      emit("items", { rev: since, items: add.items });
      await follow(env, chat.id, since, emit, gone);
    }, streamHeaders);
  }

  /** POST /ai/chats {text, attachments?, page, year, lang, today} starts a chat; POST
   *  /ai/chats/{id}/messages adds a message (while no turn runs). A question that waits for
   *  its answer stays unanswered. */
  async send(id: string | null) {
    const store = this.store;
    const body = await readBody(this.ctx.req);
    const message = userMessage(body);
    const context = cleanContext(body);
    const token = randomToken(32);
    let chat: ChatRow;
    if (id === null) {
      const { family } = await this.ctx.load("view");
      await this.checkSetUp(family.id);
      const now = new Date().toISOString();
      chat = {
        id: crypto.randomUUID(),
        family_id: family.id,
        user_id: this.ctx.requireUser().id,
        title: message.title,
        status: "running",
        run_token: token,
        run_until: leaseUntil(this.env),
        stop: false,
        retries: 0,
        context: { ...context },
        activity: null,
        notes: [],
        usage: null,
        queue: [],
        rev: 0,
        created_at: now,
        updated_at: now,
      };
      await store.createChat(chat);
      // Only the newest chats are kept.
      const all = await store.listChats(family.id, chat.user_id);
      for (const old of all.slice(MAX_CHATS)) await store.deleteChat(old.id);
    } else {
      const own = await this.ownChat(id);
      await this.checkSetUp(own.family.id);
      const claimed = await store.claimChat(id, token, leaseUntil(this.env), "start");
      if (!claimed) throw new HttpError(409, "The assistant is still answering in this chat");
      chat = claimed;
    }
    const [items, messages] = await Promise.all([store.listChatItems(chat.id), store.listChatMessages(chat.id)]);
    const add = withMessage(
      items.map((r) => r.item as unknown as Item),
      messages.map((r) => r.message as unknown as StoredMessage),
      chat.notes,
      message,
    );
    return this.begin(chat, token, { ...add, context: onPage(chat, context) });
  }

  /** POST /ai/chats/{id}/queue {text, attachments?, page, year, lang, today}: a message written
   *  while the assistant answers. It waits and goes next once the turn is over; if none runs,
   *  it starts one right away. Answers 202 with the chat (follow it to see the turn). */
  async queue(id: string) {
    const store = this.store;
    const body = await readBody(this.ctx.req);
    const message = userMessage(body);
    const { family, chat } = await this.ownChat(id);
    await this.checkSetUp(family.id);
    if (chat.queue.length >= MAX_QUEUE) throw new HttpError(409, "Too many messages wait already");
    const entry: Queued = {
      id: crypto.randomUUID(),
      item: message.item as UserItem,
      content: message.content,
      context: onPage(chat, cleanContext(body)),
    };
    let row = await store.queueChatMessage(id, entry as unknown as Record<string, unknown>);
    if (!row) throw new HttpError(404, "Chat not found");
    // No turn runs (any more): the message starts one (the worker takes it from the queue).
    const token = randomToken(32);
    if (row.status === "idle" && (await store.claimChat(id, token, leaseUntil(this.env), "start"))) {
      row = (await this.release(id, token)) ?? row;
    }
    return json({ chat: summaryOf(row), id: entry.id }, 202);
  }

  /** POST /ai/chats/{id}/unqueue {id}: takes back a message that waits (unless its turn started
   *  already); answers with the chat. */
  async unqueue(id: string) {
    const body = await readBody(this.ctx.req);
    const { chat } = await this.ownChat(id);
    const row = typeof body.id === "string" ? await this.store.unqueueChatMessage(id, body.id) : null;
    return json({ chat: summaryOf(row ?? chat) });
  }

  /** POST /ai/chats/{id}/answer {id, selected, text?, page, year, lang, today}: the user's
   *  answer to the waiting question (picked options and/or an own answer); the turn goes on. */
  async answer(id: string) {
    const store = this.store;
    const body = await readBody(this.ctx.req);
    const selected = Array.isArray(body.selected)
      ? body.selected.filter((s): s is string => typeof s === "string").slice(0, 8)
      : [];
    const own = typeof body.text === "string" ? body.text.trim().slice(0, MAX_TEXT) : "";
    if (!selected.length && !own) throw new HttpError(400, "Pick an answer or write one");
    const { family } = await this.ownChat(id);
    await this.checkSetUp(family.id);
    const token = randomToken(32);
    const chat = await store.claimChat(id, token, leaseUntil(this.env), "start");
    if (!chat) throw new HttpError(409, "The assistant is still answering in this chat");
    try {
      const [items, messages] = await Promise.all([store.listChatItems(id), store.listChatMessages(id)]);
      const shown = items.map((r) => r.item as unknown as Item);
      const q = openQuestion(
        shown,
        messages.map((r) => r.message as unknown as StoredMessage),
      );
      if (!q || q.id !== body.id) throw new HttpError(409, "This question doesn't wait any more");
      const picked = selected.filter((s) => q.options.includes(s));
      const answer = { selected: picked, ...(own ? { text: own } : {}) };
      if (!picked.length && !own) throw new HttpError(400, "Pick an answer or write one");
      return await this.begin(chat, token, {
        messages: [
          {
            role: "tool",
            tool_call_id: q.id,
            content: JSON.stringify({ ...(picked.length ? { selected: picked } : {}), ...(own ? { ownAnswer: own } : {}) }),
          },
        ],
        items: [{ seq: shown.indexOf(q), item: { ...q, answer } }],
        context: onPage(chat, cleanContext(body)),
      });
    } catch (err) {
      await this.letGo(id, token);
      throw err;
    }
  }

  /** POST /ai/chats/{id}/reminders {id, applied, results?, reminders?, page, year, lang, today}:
   *  the user applied the waiting Reminders edit in the app (results: one per op, in order:
   *  {ok: true, id?} or {ok: false, error}) or declined it (applied: false); the turn goes on
   *  with that as the tool's result. `reminders` is the fresh snapshot after the change. */
  async reminders(id: string) {
    const store = this.store;
    const body = await readBody(this.ctx.req);
    if (typeof body.applied !== "boolean") throw new HttpError(400, "applied must be true or false");
    if (body.applied && !Array.isArray(body.results)) throw new HttpError(400, "results must be a list");
    const { family } = await this.ownChat(id);
    await this.checkSetUp(family.id);
    const token = randomToken(32);
    const chat = await store.claimChat(id, token, leaseUntil(this.env), "start");
    if (!chat) throw new HttpError(409, "The assistant is still answering in this chat");
    try {
      const [items, messages] = await Promise.all([store.listChatItems(id), store.listChatMessages(id)]);
      const shown = items.map((r) => r.item as unknown as Item);
      const edit = openRemindersEdit(
        shown,
        messages.map((r) => r.message as unknown as StoredMessage),
      );
      if (!edit || edit.id !== body.id) throw new HttpError(409, "This change doesn't wait any more");
      let answer: NonNullable<(Item & { kind: "reminders" })["answer"]>;
      let result: unknown;
      if (body.applied) {
        const raw = body.results as unknown[];
        const results = edit.ops.map((_, i) => cleanResult(raw[i]));
        answer = { applied: true, results };
        result = {
          applied: true,
          results: edit.ops.map((op, i) => ({
            op: op.op,
            title: op.op === "add" ? op.title : op.itemTitle,
            ...results[i],
          })),
        };
      } else {
        answer = { applied: false };
        result = { applied: false, note: "The user declined these changes: nothing was changed in their Reminders." };
      }
      return await this.begin(chat, token, {
        messages: [{ role: "tool", tool_call_id: edit.id, content: JSON.stringify(result) }],
        items: [{ seq: shown.indexOf(edit), item: { ...edit, answer } }],
        context: onPage(chat, cleanContext(body)),
      });
    } catch (err) {
      await this.letGo(id, token);
      throw err;
    }
  }

  /** POST /ai/chats/{id}/page {page}: moves the chat to another page; its next turn is about
   *  that page. Answers with the chat. */
  async move(id: string) {
    const body = await readBody(this.ctx.req);
    const page = cleanPage(body.page);
    if (!page) throw new HttpError(400, "Unknown page");
    const { chat } = await this.ownChat(id);
    const row = await this.store.updateChat(id, { context: { ...chat.context, page } });
    if (!row) throw new HttpError(404, "Chat not found");
    return json({ chat: summaryOf(row) });
  }

  /** POST /ai/chats/{id}/stop: the running turn stops after what it is doing (the worker
   *  notices within a second); it ends with what it did so far. */
  async stop(id: string) {
    const { chat } = await this.ownChat(id);
    if (chat.status !== "running") return json({ chat: summaryOf(chat) });
    const row = await this.store.updateChat(id, { stop: true });
    return json({ chat: summaryOf(row ?? chat) });
  }

  /** POST /ai/chats/{id}/undone {id}: the app undid the change `id` of the chat. */
  async undone(id: string) {
    const store = this.store;
    const body = await readBody(this.ctx.req);
    const { chat } = await this.ownChat(id);
    const items = await store.listChatItems(id);
    const row = items.find((r) => r.item.kind === "change" && r.item.id === body.id);
    if (!row) throw new HttpError(404, "Change not found");
    const item = row.item as unknown as Item & { kind: "change" };
    if (item.undone) return json({ ok: true });
    await store.putChatItems(id, [{ seq: row.seq, item: { ...item, undone: true } }]);
    await store.updateChat(id, { notes: [...chat.notes, item.summary] });
    return json({ ok: true });
  }

  /** POST /ai/chats/import {title, updatedAt, items, history}: a chat kept elsewhere (the
   *  family-planner app kept chats on the device before they were stored). */
  async importChat() {
    const store = this.store;
    const { family } = await this.ctx.load("view");
    const user = this.ctx.requireUser();
    const body = await readBody(this.ctx.req);
    const items = cleanItems(body.items);
    let history: ChatMessage[] = [];
    try {
      history = windowHistory(
        (Array.isArray(body.history) ? body.history : []).slice(-MAX_IMPORT_MESSAGES).map(cleanMessage),
      );
    } catch {
      // Not usable for the model: the chat is shown, and the next turn starts without it.
    }
    if (!items.length) throw new HttpError(400, "The chat is empty");
    const last = history.at(-1);
    if (last && (last.role !== "assistant" || last.tool_calls?.length)) {
      history.push({ role: "assistant", content: STOPPED });
    }
    const updated =
      typeof body.updatedAt === "number" && Number.isFinite(body.updatedAt)
        ? new Date(Math.min(body.updatedAt, Date.now())).toISOString()
        : new Date().toISOString();
    const title = typeof body.title === "string" && body.title.trim() ? body.title.trim().slice(0, MAX_TITLE) : "Chat";
    const chat: ChatRow = {
      id: crypto.randomUUID(),
      family_id: family.id,
      user_id: user.id,
      title,
      status: "idle",
      run_token: null,
      run_until: null,
      stop: false,
      retries: 0,
      context: {},
      activity: null,
      notes: [],
      usage: null,
      queue: [],
      rev: 0,
      created_at: updated,
      updated_at: updated,
    };
    await store.createChat(chat);
    await store.addChatMessages(
      chat.id,
      history.map((m, seq) => ({ seq, message: m as unknown as Record<string, unknown> })),
    );
    await store.putChatItems(
      chat.id,
      items.map((item, seq) => ({ seq, item: item as unknown as Record<string, unknown> })),
    );
    // It keeps the time it was last used, so it sorts among the others.
    const row = await store.updateChat(chat.id, { updated_at: updated });
    return json({ chat: summaryOf(row ?? chat) }, 201);
  }
}

/** The text and attachments of a message: what the chat shows, and the model's content (the
 *  text, then the text files, then the images). */
function userMessage(body: Record<string, unknown>) {
  const text = typeof body.text === "string" ? body.text.trim() : "";
  if (text.length > MAX_TEXT) throw new HttpError(400, "The message is too long");
  const raw = body.attachments ?? [];
  if (!Array.isArray(raw) || raw.length > MAX_ATTACHMENTS) {
    throw new HttpError(400, `attachments must be a list of at most ${MAX_ATTACHMENTS}`);
  }
  const attachments = raw.map((r) => {
    const a = objectOf(r, "Each attachment");
    const name = typeof a.name === "string" && a.name.trim() ? a.name.trim().slice(0, 200) : "file";
    if (a.kind === "image" && typeof a.url === "string") return { kind: "image" as const, name, url: a.url, text: "" };
    if (a.kind === "file" && typeof a.text === "string") return { kind: "file" as const, name, url: "", text: a.text };
    throw new HttpError(400, "An attachment is an image (url) or a file (text)");
  });
  if (!text && !attachments.length) throw new HttpError(400, "The message is empty");
  const parts: ContentPart[] = [];
  if (text) parts.push({ type: "text", text });
  for (const a of attachments) {
    if (a.kind === "file") parts.push({ type: "text", text: `Attached file “${a.name}”:\n\`\`\`\n${a.text}\n\`\`\`` });
  }
  for (const a of attachments) {
    if (a.kind === "image") parts.push({ type: "image_url", image_url: { url: a.url } });
  }
  const item: UserItem = { kind: "user", text };
  if (attachments.length) {
    item.attachments = attachments.map(
      (a): Attachment => (a.kind === "image" ? { kind: "image", name: a.name, url: a.url } : { kind: "file", name: a.name }),
    );
  }
  return {
    content: attachments.length ? cleanParts(parts) : text,
    item,
    title: (text || attachments[0].name).slice(0, MAX_TITLE),
  };
}

/** Undo steps of an imported change: requests on the family's own API, as the app makes them. */
function cleanUndo(raw: unknown): unknown[] {
  if (!Array.isArray(raw) || JSON.stringify(raw).length > 200_000) return [];
  return raw
    .slice(0, 50)
    .filter(
      (s) =>
        s &&
        typeof s === "object" &&
        ["POST", "PATCH", "DELETE"].includes(s.method) &&
        typeof s.path === "string" &&
        /^\/[\w\-/?=&.%]*$/.test(s.path) &&
        !s.path.includes(".."),
    )
    .map((s) => ({ method: s.method, path: s.path, ...(s.body !== undefined ? { body: s.body } : {}) }));
}

const str = (v: unknown, max = MAX_TEXT) => (typeof v === "string" ? v.slice(0, max) : "");

/** What the app reports for one op of a Reminders edit; a missing one failed. */
function cleanResult(raw: unknown): ReminderResult {
  const o = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  if (o.ok === true) return typeof o.id === "string" && o.id ? { ok: true, id: o.id.slice(0, 200) } : { ok: true };
  return { ok: false, error: str(o.error, 500) || (raw === undefined ? "No result" : "Failed") };
}

/** Items of an imported chat: only what the app can show, with the expected fields. */
function cleanItems(raw: unknown): Item[] {
  if (!Array.isArray(raw)) throw new HttpError(400, "items must be a list");
  return raw.slice(-MAX_IMPORT_ITEMS).flatMap((r): Item[] => {
    if (!r || typeof r !== "object") return [];
    const o = r as Record<string, unknown>;
    switch (o.kind) {
      case "user": {
        const attachments = (Array.isArray(o.attachments) ? o.attachments : [])
          .slice(0, 8)
          .filter((a) => a && typeof a === "object")
          .map((a): Attachment => {
            const url = str(a.url, 2_000_000);
            return {
              kind: a.kind === "image" ? "image" : "file",
              name: str(a.name, 200) || "file",
              ...(a.kind === "image" && IMAGE_URL.test(url) ? { url } : {}),
            };
          });
        return [{ kind: "user", text: str(o.text), ...(attachments.length ? { attachments } : {}) }];
      }
      case "assistant":
        return [{ kind: "assistant", text: str(o.text) }];
      case "error":
        return [{ kind: "error", text: str(o.text, 2000) }];
      case "tool":
        return [
          {
            kind: "tool",
            id: str(o.id, 200),
            name: str(o.name, 100),
            args: o.args && typeof o.args === "object" && JSON.stringify(o.args).length < 20_000 ? o.args : {},
            status: o.status === "ok" ? "ok" : "error",
            ...(typeof o.summary === "string" ? { summary: str(o.summary, 2000) } : {}),
          },
        ];
      case "change":
        return [
          {
            kind: "change",
            id: str(o.id, 200),
            change: str(o.change, 40),
            summary: str(o.summary, 2000),
            undo: cleanUndo(o.undo),
            ...(o.undone === true ? { undone: true } : {}),
          },
        ];
      case "reminders": {
        const ops = Array.isArray(o.ops) && JSON.stringify(o.ops).length < 100_000 ? o.ops.slice(0, 50) : [];
        const a = o.answer as { applied?: unknown; results?: unknown } | undefined;
        return [
          {
            kind: "reminders",
            id: str(o.id, 200),
            summary: str(o.summary, 2000),
            ops: ops.filter((op) => op && typeof op === "object") as ReminderOp[],
            ...(a && typeof a === "object" && typeof a.applied === "boolean"
              ? {
                  answer: a.applied
                    ? { applied: true, results: (Array.isArray(a.results) ? a.results : []).slice(0, 50).map(cleanResult) }
                    : { applied: false },
                }
              : { skipped: true }),
          },
        ];
      }
      case "question": {
        const options = (Array.isArray(o.options) ? o.options : []).map((v) => str(v, 500)).slice(0, 8);
        const a = o.answer as { selected?: unknown; text?: unknown } | undefined;
        return [
          {
            kind: "question",
            id: str(o.id, 200),
            question: str(o.question, 2000),
            options,
            multiple: o.multiple === true,
            ...(a && typeof a === "object"
              ? {
                  answer: {
                    selected: (Array.isArray(a.selected) ? a.selected : []).map((v) => str(v, 500)).slice(0, 8),
                    ...(typeof a.text === "string" ? { text: str(a.text) } : {}),
                  },
                }
              : { skipped: true }),
          },
        ];
      }
    }
    return [];
  });
}
