// The AI chats, kept on the server (ported from family-planner's ai/chats.ts): each user has
// their own chats per family, stored with what they show (items) and what the model gets back
// (messages). A turn runs in the worker, never in a request (see runner.ts): the web process
// only saves the user's message and marks the chat as running without a holder; the worker
// takes it (`claimChat` with a new token, the lease `run_until` renewed while it works), so a
// worker that dies leaves a turn the next one takes over. The app, on any device, follows a
// chat from the database (chat-routes.ts). A turn runs as long as the model works on; when the
// chat gets too long for the model's context window, its older part is condensed into a
// summary (see context.ts), kept with the messages. Messages written while a turn runs wait in
// the chat's queue; once the turn is over, the next one goes on.
//
// family-planner's hand-off between Edge Function invocations (POST …/resume) is gone: the
// worker has no time limit, so a turn that would have handed itself on just goes on.

import type { FamilyRow } from "@/lib/calendar/store";
import { HttpError } from "@/lib/api/http";
import { type ChatContext, cleanPage, type Emit, runChat } from "./chat";
import { type StoredMessage, type SummaryMark, viewOf } from "./context";
import type { ChatMessage, Provider, ToolCall } from "./provider";
import type { AssistantStore, ChatRow } from "./store";
import type { NetOptions } from "./net";
import type { AppleCalendarOp, ReminderOp, ToolContext } from "./tools";

/** What a turn needs from the family's AI settings. */
export interface Turn {
  provider: Provider;
  system: string;
  ctx: ToolContext;
  /** Requests to the model (its endpoint may be on the home network, pages never). */
  modelNet: NetOptions;
  writes: boolean;
  search: boolean;
  /** The model's context window in tokens. */
  window: number;
}

/** Sets up the turn of a chat: its model, the instructions for the context, the tools. */
export type Prepare = (chat: ChatRow, family: FamilyRow, context: ChatContext, signal: AbortSignal) => Promise<Turn>;

/** What the chats need: the store, and timings (tests make them short). */
export interface ChatEnv {
  store: AssistantStore;
  /** How long a turn holds the chat without renewing it. */
  leaseMs?: number;
  /** How often a running turn renews its hold (and notices a stop). */
  heartbeatMs?: number;
  /** How long a failed step waits before it is tried again (times the tries). */
  retryMs?: number;
  /** How often streaming text is saved at most. */
  saveMs?: number;
  /** How often a follower looks for news, and how long its stream lasts. */
  pollMs?: number;
  streamMs?: number;
}

/** What the chat shows, in order (the app renders these). */
export type Item =
  | { kind: "user"; text: string; attachments?: Attachment[] }
  | { kind: "assistant"; text: string }
  | {
      kind: "tool";
      id: string;
      name: string;
      args: unknown;
      status: "running" | "ok" | "error";
      summary?: string;
      /** The start of what the model got back. */
      result?: string;
      /** It was running when its turn broke off. */
      interrupted?: boolean;
    }
  | {
      kind: "change";
      id: string;
      change: string;
      summary: string;
      undo: unknown[];
      undone?: boolean;
    }
  | {
      kind: "question";
      id: string;
      question: string;
      options: string[];
      multiple: boolean;
      answer?: { selected: string[]; text?: string };
      skipped?: boolean;
    }
  /** A change of the user's Reminders (edit_reminders) that waits for them to apply or decline
   *  it in the app (POST …/reminders), like a question. */
  | {
      kind: "reminders";
      id: string;
      summary: string;
      ops: ReminderOp[];
      answer?: EditAnswer;
      skipped?: boolean;
    }
  /** A change of the user's device calendars (edit_apple_calendar), the same way (POST
   *  …/calendar). */
  | {
      kind: "calendar";
      id: string;
      summary: string;
      ops: AppleCalendarOp[];
      answer?: EditAnswer;
      skipped?: boolean;
    }
  /** The older part of the chat was condensed for the model from here on. */
  | { kind: "compacted" }
  | { kind: "error"; text: string };

export type Attachment = { kind: "image" | "file"; name: string; url?: string };
/** What the app reports per op of an edit of the device's data (Reminders, calendars) it
 *  applied. */
export type EditResult = { ok: true; id?: string } | { ok: false; error: string };
/** @deprecated The old name of EditResult. */
export type ReminderResult = EditResult;
/** The user's answer to an edit of the device's data: applied (how each op went) or declined. */
export type EditAnswer = { applied: true; results: EditResult[] } | { applied: false };
export type UserItem = Item & { kind: "user" };

/** A message that waits for the running turn to end: what the chat shows, what the model gets,
 *  and where the user was. */
export interface Queued {
  id: string;
  item: UserItem;
  content: ChatMessage["content"];
  context: ChatContext;
}
type ToolItem = Item & { kind: "tool" };
export type QuestionItem = Item & { kind: "question" };
export type RemindersItem = Item & { kind: "reminders" };
export type CalendarItem = Item & { kind: "calendar" };
/** An edit of the device's data that waits for the user's OK. */
export type EditItem = RemindersItem | CalendarItem;
export type EditKind = EditItem["kind"];
/** What waits for the user: a question, or an edit of their Reminders or calendars. */
export type WaitingItem = QuestionItem | EditItem;
const WAITING_KINDS = new Set<string>(["question", "reminders", "calendar"] satisfies WaitingItem["kind"][]);
/** Where the changes of an edit would have gone, for what the model hears about it. */
export const EDIT_PLACE: Record<EditKind, string> = { reminders: "their Reminders", calendar: "their calendars" };

/** What a running turn does right now. */
type Activity =
  | { kind: "thinking" | "writing" | "tool" | "compacting" }
  | { kind: "retrying"; attempt: number; max: number };

/** A turn that doesn't renew its hold on the chat for this long is taken over. */
export const LEASE_MS = 30_000;
const HEARTBEAT_MS = 5_000;
/** Streaming text is saved at most this often (followers read it from the database). */
const SAVE_MS = 500;
/** Times a failed step is tried again before the turn gives up. */
const MAX_RETRIES = 5;
const RETRY_MS = 1000;
/** Characters of a tool result the chat shows (copying a chat includes them). */
const MAX_RESULT_SHOWN = 2000;

export const STOPPED = "(stopped)";
/** What the model learns about a question the user didn't answer. */
const SKIPPED = JSON.stringify({
  skipped: true,
  note: "The user didn't pick an answer and wrote a new message instead, which may answer it.",
});
/** What the model learns about an edit (of their Reminders or calendars) the user neither
 *  applied nor declined. */
const skippedEdit = (kind: EditKind) =>
  JSON.stringify({
    skipped: true,
    note: `The user neither applied nor declined these changes and wrote a new message instead: nothing was changed in ${EDIT_PLACE[kind]}.`,
  });
/** What the model learns about a tool that was running when its turn broke off. */
const INTERRUPTED = JSON.stringify({
  error: "Interrupted: this may or may not have been done. Check before doing it again.",
});
const GAVE_UP = "The assistant stopped answering.";

export type Summary = ReturnType<typeof summaryOf>;
/** How full the model's context is: tokens in use, and the window. */
type Usage = { used: number; max: number };

export function summaryOf(c: ChatRow) {
  return {
    id: c.id,
    title: c.title,
    status: c.status,
    activity: c.status === "running" ? c.activity : null,
    usage: (c.usage ?? null) as Usage | null,
    /** The page the chat belongs to (null for a chat from before chats kept one). */
    page: cleanPage((c.context as Partial<ChatContext> | null)?.page),
    queued: queuedOf(c),
    updatedAt: c.updated_at,
  };
}

/** Where the user is, for a message to `chat`: the chat stays on its page (moving it is a
 *  request of its own); a chat without one takes the user's. */
export function onPage(chat: ChatRow, context: ChatContext): ChatContext {
  const page = cleanPage((chat.context as Partial<ChatContext> | null)?.page);
  return page ? { ...context, page } : context;
}

/** The messages that wait, as the chat shows them (attachments by name only). */
function queuedOf(c: ChatRow) {
  return ((c.queue ?? []) as unknown as Queued[]).map(({ id, item }) => ({
    id,
    text: item.text,
    ...(item.attachments?.length ? { attachments: item.attachments.map(({ kind, name }) => ({ kind, name })) } : {}),
  }));
}

export const leaseUntil = (env: ChatEnv) => new Date(Date.now() + (env.leaseMs ?? LEASE_MS)).toISOString();

/** Resolves after `ms`, or as soon as `signal` aborts. */
export function pause(ms: number, signal?: AbortSignal) {
  return new Promise<void>((resolve) => {
    if (signal?.aborted) return resolve();
    const timer = setTimeout(done, ms);
    signal?.addEventListener("abort", done, { once: true });
    function done() {
      clearTimeout(timer);
      signal?.removeEventListener("abort", done);
      resolve();
    }
  });
}

/** The turn is over: answered, or a question (or an edit) waits for the user. */
function over(items: Item[], messages: StoredMessage[]) {
  const last = messages.at(-1);
  return !last || (last.role === "assistant" && !last.tool_calls?.length) || !!waitingFor(items, messages);
}

/** What a new message adds: a question (or an edit) that waits stays unanswered, the
 *  changes undone since are told (so the assistant doesn't assume they are still there), then
 *  the message itself. */
export function withMessage(
  shown: Item[],
  messages: StoredMessage[],
  notes: string[],
  message: { content: ChatMessage["content"]; item: Item },
) {
  const add: { messages: ChatMessage[]; items: { seq: number; item: Item }[] } = { messages: [], items: [] };
  const q = waitingFor(shown, messages);
  if (q) {
    add.items.push({ seq: shown.indexOf(q), item: { ...q, skipped: true } });
    add.messages.push({ role: "tool", tool_call_id: q.id, content: q.kind === "question" ? SKIPPED : skippedEdit(q.kind) });
  }
  for (const note of notes) {
    add.messages.push({ role: "user", content: `(I undid this change: ${note})` }, { role: "assistant", content: "OK." });
  }
  add.messages.push({ role: "user", content: message.content });
  add.items.push({ seq: shown.length, item: message.item });
  return add;
}

const isWaiting = (it: Item | undefined): it is WaitingItem => !!it && WAITING_KINDS.has(it.kind);

/** The question or edit that waits for its answer: the last one, unanswered, while the history
 *  ends with its call. */
export function waitingFor(items: Item[], messages: StoredMessage[]): WaitingItem | undefined {
  const q = items.findLast(isWaiting);
  if (!q || q.answer || q.skipped) return undefined;
  const last = messages.at(-1);
  const asked = messages.findLast((m) => m.tool_calls?.some((c) => c.id === q.id));
  const answered = messages.some((m) => m.role === "tool" && m.tool_call_id === q.id);
  return asked && !answered && last?.role !== "user" ? q : undefined;
}

/** The question that waits for its answer (see waitingFor). */
export function openQuestion(items: Item[], messages: StoredMessage[]): QuestionItem | undefined {
  const q = waitingFor(items, messages);
  return q?.kind === "question" ? q : undefined;
}

/** The edit of this kind that waits for the user to apply or decline it (see waitingFor). */
export function openEdit<K extends EditKind>(
  kind: K,
  items: Item[],
  messages: StoredMessage[],
): (Item & { kind: K }) | undefined {
  const q = waitingFor(items, messages);
  return q?.kind === kind ? (q as Item & { kind: K }) : undefined;
}

/** The Reminders edit that waits for the user to apply or decline it (see waitingFor). */
export function openRemindersEdit(items: Item[], messages: StoredMessage[]): RemindersItem | undefined {
  return openEdit("reminders", items, messages);
}

type Outcome = { kind: "done" | "handoff" | "stopped" | "lost" } | { kind: "retry"; message: string };

/** What the worker gives a turn. */
export interface RunnerEnv extends ChatEnv {
  prepare: Prepare;
  /** After a turn ended (not when it was lost to another worker): how it went and when it
   *  started (ms), e.g. to notify the user (notify.ts). Never throws into the turn. */
  turnEnded?: (chat: ChatRow, info: { startedAt: number; outcome: "answered" | "failed" | "stopped" }) => Promise<void>;
  /** The chat's family; null if it is gone. */
  family: (id: string) => Promise<FamilyRow | null>;
}

/** Runs a chat's turn in the worker: the tool loop (runChat), with what it does saved as items
 *  and messages, until it is answered, waits for an answer, or is stopped. The chat must be
 *  claimed for `token`. `abort` ends it: "stop" (the user asked) or "lost" (the chat is gone,
 *  or someone else holds it now). */
export class Runner {
  private chat!: ChatRow;
  private items: Item[] = [];
  private messages: StoredMessage[] = [];
  private activity: Activity | null = null;
  private usage: Usage | null = null;
  private retries = 0;
  private queue: Promise<void> = Promise.resolve();
  private failed = false;
  private dirty = new Set<number>();
  private timer: ReturnType<typeof setTimeout> | undefined;
  private beating = true;
  /** The step that is running: runChat sends its messages once it is done. */
  private step = { text: "", calls: [] as ToolCall[], results: new Map<string, string>() };
  /** Where the step's text goes. */
  private answer: number | null = null;
  private store: AssistantStore;
  private startedAt = Date.now();
  private failedTurn = false;

  constructor(
    private env: RunnerEnv,
    private id: string,
    private token: string,
    readonly abort = new AbortController(),
  ) {
    this.store = env.store;
  }

  private get signal() {
    return this.abort.signal;
  }

  /** Saves in order; after a failed save the turn can't go on (it ends as "lost"). */
  private write(fn: () => Promise<unknown>) {
    this.queue = this.queue.then(async () => {
      if (this.failed) return;
      try {
        await fn();
      } catch (err) {
        console.error("[assistant] saving the chat failed:", err);
        this.failed = true;
        this.abort.abort("lost");
      }
    });
    return this.queue;
  }

  private set(seq: number, item: Item) {
    this.items[seq] = item;
    this.dirty.add(seq);
  }

  private add(item: Item): number {
    const seq = this.items.length;
    this.set(seq, item);
    return seq;
  }

  private saveItems() {
    clearTimeout(this.timer);
    this.timer = undefined;
    if (!this.dirty.size) return;
    const rows = [...this.dirty].map((seq) => ({ seq, item: this.items[seq] as unknown as Record<string, unknown> }));
    this.dirty.clear();
    this.write(async () => {
      if ((await this.store.putChatItems(this.id, rows)) === null) throw new Error("Chat gone");
    });
  }

  private saveSoon() {
    this.timer ??= setTimeout(() => this.saveItems(), this.env.saveMs ?? SAVE_MS);
  }

  private addMessages(list: StoredMessage[]) {
    const rows = list.map((message, i) => ({
      seq: this.messages.length + i,
      message: message as unknown as Record<string, unknown>,
    }));
    this.messages.push(...list);
    this.write(() => this.store.addChatMessages(this.id, rows));
  }

  /** Holds on to the chat a little longer and saves what the turn does; notices a stop. */
  renew() {
    return this.write(async () => {
      const row = await this.store.updateChat(
        this.id,
        {
          run_until: leaseUntil(this.env),
          activity: this.activity as Record<string, unknown> | null,
          retries: this.retries,
          usage: this.usage,
        },
        this.token,
      );
      if (!row) return this.abort.abort("lost");
      this.chat = row;
      if (row.stop) this.abort.abort("stop");
    });
  }

  private doing(activity: Activity) {
    if (JSON.stringify(activity) === JSON.stringify(this.activity)) return;
    this.activity = activity;
    this.renew();
  }

  /** Runs the turn; `takeover`: a worker that held it died. */
  async drive(takeover: boolean) {
    const [chat, itemRows, messageRows] = await Promise.all([
      this.store.getChat(this.id),
      this.store.listChatItems(this.id),
      this.store.listChatMessages(this.id),
    ]);
    if (!chat || chat.run_token !== this.token) return;
    this.chat = chat;
    for (const r of itemRows) this.items[r.seq] = r.item as unknown as Item;
    this.messages = messageRows.map((r) => r.message as unknown as StoredMessage);
    this.activity = chat.activity as Activity | null;
    this.usage = chat.usage as Usage | null;
    // A turn taken over from a worker that died counts as a failed try.
    this.retries = chat.retries + (takeover ? 1 : 0);
    const beat = setInterval(() => {
      if (this.beating) this.renew();
    }, this.env.heartbeatMs ?? HEARTBEAT_MS);
    try {
      await this.loop();
    } finally {
      clearInterval(beat);
      clearTimeout(this.timer);
      await this.queue;
    }
  }

  private async loop() {
    this.repair();
    if (this.chat.stop) return this.finish(STOPPED);
    if (this.retries > MAX_RETRIES) return this.fail(GAVE_UP);
    // Started for a message that waited: the turn is about it.
    if (over(this.items, this.messages) && !(await this.next())) return this.finish();
    this.doing({ kind: "thinking" });
    const family = await this.env.family(this.chat.family_id);
    if (!family) return;
    let turn: Turn;
    try {
      turn = await this.env.prepare(this.chat, family, this.chat.context as unknown as ChatContext, this.signal);
    } catch (err) {
      if (!(err instanceof HttpError)) console.error("[assistant] preparing a turn failed:", err);
      return this.fail(err instanceof HttpError ? err.message : "The assistant failed");
    }
    for (;;) {
      // Answered already, or a question (or an edit) waits for the user.
      if (over(this.items, this.messages)) return this.finish();
      const outcome = await this.go(turn);
      switch (outcome.kind) {
        case "done":
          return this.finish();
        case "stopped":
          return this.finish(STOPPED);
        case "lost":
          return;
        case "handoff":
          // family-planner handed the turn to a new invocation here; the worker goes on.
          this.saveItems();
          continue;
        case "retry":
          if (++this.retries > MAX_RETRIES) return this.fail(outcome.message);
          this.doing({ kind: "retrying", attempt: this.retries, max: MAX_RETRIES });
          await pause(this.retries * (this.env.retryMs ?? RETRY_MS), this.signal);
          if (this.signal.aborted) {
            if (this.signal.reason === "stop") await this.finish(STOPPED);
            return;
          }
          this.doing({ kind: "thinking" });
      }
    }
  }

  /** Takes the next message that waits, and the turn goes on with it; false if none waits. */
  private async next(): Promise<boolean> {
    const chat = await this.store.getChat(this.id);
    for (const q of (chat?.queue ?? []) as unknown as Queued[]) {
      // Taken back meanwhile: the next one.
      const row = await this.store.unqueueChatMessage(this.id, q.id);
      if (!row) continue;
      const add = withMessage(this.items, this.messages, row.notes, q);
      for (const { seq, item } of add.items) this.set(seq, item);
      this.addMessages(add.messages);
      this.saveItems();
      await this.write(async () => {
        const after = await this.store.updateChat(
          this.id,
          { context: { ...onPage(row, q.context) }, notes: [] },
          this.token,
        );
        if (!after) return this.abort.abort("lost");
        this.chat = after;
      });
      return true;
    }
    return false;
  }

  /** Runs the tool loop until it ends, and keeps what it does. */
  private async go(turn: Turn): Promise<Outcome> {
    // Set by the events (a closure, so TypeScript doesn't narrow it).
    let outcome = { kind: "lost" } as Outcome;
    this.step = { text: "", calls: [], results: new Map() };
    this.answer = null;
    const tools = new Map<string, number>();
    const emit: Emit = (event, raw) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const data = raw as any;
      switch (event) {
        case "text": {
          this.doing({ kind: "writing" });
          this.answer ??= this.newAnswer();
          const it = this.items[this.answer] as Item & { kind: "assistant" };
          this.items[this.answer] = { ...it, text: it.text + data.delta };
          this.dirty.add(this.answer);
          this.step.text += data.delta;
          this.saveSoon();
          break;
        }
        case "tool":
          this.answer = null; // text after the tool goes into a new bubble
          this.step.calls.push({
            id: data.id,
            type: "function",
            function: { name: data.name, arguments: JSON.stringify(data.args) },
          });
          tools.set(data.id, this.add({ kind: "tool", id: data.id, name: data.name, args: data.args, status: "running" }));
          this.saveItems();
          this.doing({ kind: "tool" });
          break;
        case "tool_result": {
          this.step.results.set(data.id, JSON.stringify({ ok: data.ok, summary: data.summary }));
          const seq = tools.get(data.id);
          if (seq !== undefined) {
            const it = this.items[seq] as ToolItem;
            this.set(seq, { ...it, status: data.ok ? "ok" : "error", summary: data.summary });
          }
          this.saveItems();
          // Once its tools are done, the model reads the results and decides what's next.
          if (![...tools.values()].some((s) => (this.items[s] as ToolItem).status === "running")) {
            this.doing({ kind: "thinking" });
          }
          break;
        }
        case "change":
          this.add({ kind: "change", id: data.id, change: data.kind, summary: data.summary, undo: data.undo });
          this.saveItems();
          break;
        case "question":
          this.answer = null;
          this.add({ kind: "question", ...data });
          this.saveItems();
          outcome = { kind: "done" };
          break;
        case "reminders":
        case "calendar":
          this.answer = null;
          this.add({ kind: event, id: data.id, summary: data.summary, ops: data.ops });
          this.saveItems();
          outcome = { kind: "done" };
          break;
        case "messages": {
          const list = data.messages as ChatMessage[];
          for (const m of list) {
            const seq = m.role === "tool" ? tools.get(m.tool_call_id ?? "") : undefined;
            if (seq !== undefined && typeof m.content === "string") {
              this.set(seq, { ...(this.items[seq] as ToolItem), result: shorten(m.content) });
            }
          }
          this.addMessages(list);
          this.saveItems();
          this.answer = null;
          this.step = { text: "", calls: [], results: new Map() };
          this.retries = 0;
          break;
        }
        case "usage":
          if (data.used === this.usage?.used && data.max === this.usage?.max) break;
          this.usage = { used: data.used, max: data.max };
          this.renew();
          break;
        case "compacting":
          this.doing({ kind: "compacting" });
          break;
        case "compacted": {
          // The summary stands for the messages before the newest `keep` (summaries aside).
          let from = this.messages.length;
          for (let n = data.keep; n > 0; ) if (this.messages[--from].role !== "summary") n--;
          const mark: SummaryMark = {
            role: "summary",
            content: data.summary,
            ...(data.request !== undefined ? { request: data.request } : {}),
            from,
          };
          this.addMessages([mark]);
          this.answer = null;
          this.add({ kind: "compacted" });
          this.saveItems();
          this.doing({ kind: "thinking" });
          break;
        }
        case "done":
          outcome = { kind: "done" };
          break;
        case "continue":
          outcome = data.retry ? { kind: "retry", message: data.message } : { kind: "handoff" };
          break;
      }
    };
    const at = this.messages.findLastIndex((m) => m.role === "summary");
    await runChat({
      ...turn,
      history: viewOf(this.messages),
      summary: at < 0 ? null : (this.messages[at] as SummaryMark),
      emit,
      signal: this.signal,
      // The worker has no time limit: a step is only cut off by the model call's timeout.
      handOffMs: Infinity,
      deadlineMs: Infinity,
    });
    if (this.signal.aborted) {
      if (this.signal.reason !== "stop") return { kind: "lost" };
      this.recover();
      return { kind: "stopped" };
    }
    if (outcome.kind === "retry") this.recover();
    return outcome;
  }

  /** Where new text goes: a blank answer left by a step that broke off, else a new one. */
  private newAnswer(): number {
    const last = this.items.at(-1);
    return last?.kind === "assistant" && !last.text ? this.items.length - 1 : this.add({ kind: "assistant", text: "" });
  }

  /** After a step broke off: keep what it did, so it isn't done twice. */
  private recover() {
    const { calls, text, results } = this.step;
    if (calls.length) {
      // Its tools ran (some maybe only partly): tell the model what is known about them.
      this.addMessages([
        { role: "assistant", content: text || null, tool_calls: calls },
        ...calls.map(
          (call): ChatMessage => ({ role: "tool", tool_call_id: call.id, content: results.get(call.id) ?? INTERRUPTED }),
        ),
      ]);
      this.interruptTools();
    } else if (this.answer !== null) {
      // Only text so far: the step runs again, so its text goes.
      this.set(this.answer, { kind: "assistant", text: "" });
    }
    this.answer = null;
    this.step = { text: "", calls: [], results: new Map() };
    this.saveItems();
  }

  private interruptTools() {
    this.items.forEach((it, seq) => {
      if (it?.kind === "tool" && it.status === "running") this.set(seq, { ...it, status: "error", interrupted: true });
    });
  }

  /** At the start: what a worker that died left behind. Its step's tools are told to the model
   *  like after a failed step, and text it was writing goes (the step runs again). */
  private repair() {
    const known = new Set(this.messages.flatMap((m) => m.tool_calls?.map((c) => c.id) ?? []));
    const turn = this.items.findLastIndex((it) => it?.kind === "user");
    const lost = this.items
      .slice(turn + 1)
      .filter((it): it is ToolItem => it?.kind === "tool" && !known.has(it.id));
    if (lost.length) {
      this.addMessages([
        {
          role: "assistant",
          content: null,
          tool_calls: lost.map((it) => ({
            id: it.id,
            type: "function" as const,
            function: { name: it.name, arguments: JSON.stringify(it.args ?? {}) },
          })),
        },
        ...lost.map(
          (it): ChatMessage => ({
            role: "tool",
            tool_call_id: it.id,
            content: it.status === "running" ? INTERRUPTED : JSON.stringify({ ok: it.status === "ok", summary: it.summary }),
          }),
        ),
      ]);
    }
    this.interruptTools();
    const last = this.items.at(-1);
    const answered = this.messages.at(-1)?.role === "assistant" && !this.messages.at(-1)?.tool_calls?.length;
    if (last?.kind === "assistant" && last.text && !answered) {
      this.set(this.items.length - 1, { kind: "assistant", text: "" });
    }
    this.saveItems();
  }

  /** Ends a turn that has no answer (stopped, failed) with `note`, so the history stays valid
   *  for the next one. */
  private close(note: string) {
    const last = this.messages.at(-1);
    if (last && (last.role !== "assistant" || last.tool_calls?.length)) {
      this.addMessages([{ role: "assistant", content: note }]);
    }
  }

  private fail(message: string) {
    this.failedTurn = true;
    this.add({ kind: "error", text: message });
    return this.finish(`(No answer: ${message})`);
  }

  /** Saves everything and lets go of the chat: no turn runs any more. Messages that wait start
   *  the next turn (the worker takes the chat again). */
  private async finish(note?: string) {
    if (note) this.close(note);
    this.saveItems();
    this.beating = false;
    let after: ChatRow | null = null;
    await this.write(async () => {
      after = await this.store.updateChat(
        this.id,
        { status: "idle", run_token: null, run_until: null, stop: false, activity: null, retries: 0 },
        this.token,
      );
    });
    if (after && this.env.turnEnded) {
      const outcome = note === STOPPED ? "stopped" : this.failedTurn ? "failed" : "answered";
      await this.env.turnEnded(after, { startedAt: this.startedAt, outcome }).catch((err) =>
        console.error("[assistant] after the turn:", err)
      );
    }
  }
}

const shorten = (s: string) => (s.length > MAX_RESULT_SHOWN ? s.slice(0, MAX_RESULT_SHOWN) + "…(truncated)" : s);
