// Client of the assistant's API (/api/v1/families/{id}/ai/...): family-planner's app/src/lib/
// api.ts (AI settings, categorize, chats and their event streams) and its types.

import { ApiError, enc, fam, request } from "@/lib/api/client";

export interface AiSettings {
  configured: boolean;
  /** An editor sees the setup; a viewer only whether it is set up. */
  canEdit: boolean;
  baseUrl?: string;
  model: string;
  hasKey?: boolean;
  keyHint?: string;
  searchProvider?: "none" | "tavily" | "brave";
  hasSearchKey?: boolean;
  searchKeyHint?: string;
  allowWrites: boolean;
  /** The model's context window in tokens; 0: from the API's model list (or 128,000). */
  contextWindow?: number;
  serverReady: boolean;
}

export interface AiSettingsPatch {
  baseUrl?: string;
  apiKey?: string;
  model?: string;
  searchProvider?: "none" | "tavily" | "brave";
  searchKey?: string;
  allowWrites?: boolean;
  contextWindow?: number;
}

/** An op for POST /finance/transactions; the response's `inverse` ops undo a request. */
export type TransactionOp = Record<string, unknown>;

/** What one POST /ai/categorize call did; `inverse` undoes it. */
export interface CategorizeResult {
  changed: number; // how many got a category
  matched: number; // of these, how many like similar earlier ones (no AI)
  considered: number; // how many the model looked at (at most 200)
  remaining: number; // uncategorized ones after these, not looked at yet
  ai: boolean; // whether the AI is set up (without, only similar ones are matched)
  inverse: TransactionOp[];
  assignments: { id: string; categoryId: string; source: "similar" | "ai" }[];
}

/** A request against /families/{id} that undoes (part of) a change the assistant made. */
export interface UndoStep {
  method: "POST" | "PATCH" | "DELETE";
  path: string;
  body?: unknown;
}

/** A question of the assistant: pick one option (or several) or write an own answer. */
export interface ChatQuestion {
  id: string;
  question: string;
  options: string[];
  multiple: boolean;
}

/** What a running turn does right now. */
export type ChatActivity =
  | { kind: "thinking" | "writing" | "tool" | "compacting" }
  | { kind: "retrying"; attempt: number; max: number };

/** How full the model's context is: the tokens the chat uses, and the most it takes. */
export interface ChatUsage {
  used: number;
  max: number;
}

/** A message written while the assistant answered: it goes next (attachments by name). */
export interface ChatQueued {
  id: string;
  text: string;
  attachments?: { kind: "image" | "file"; name: string }[];
}

/** A chat as the list shows it; the worker runs its turns. */
export interface ChatSummary {
  id: string;
  title: string;
  status: "idle" | "running";
  activity: ChatActivity | null;
  /** At its last step (null before the first). */
  usage: ChatUsage | null;
  /** The page the chat belongs to: its turns are about that page (null for an old chat). */
  page?: string | null;
  /** Messages waiting for the running turn to end, in order. */
  queued?: ChatQueued[];
  updatedAt: string;
}

/** A chat with what it shows (the items, by position) and their revision. */
export interface ChatState<Item = unknown> {
  chat: ChatSummary;
  rev: number;
  items: Item[];
}

/** What a chat's stream sends: the chat, items that changed (by position; `rev` once they are
 *  saved up to that revision), then the end (no turn runs any more) or "reconnect" (ask again
 *  to go on following). */
export type ChatEvent<Item = unknown> =
  | { event: "chat"; data: ChatSummary }
  | { event: "items"; data: { rev?: number; items: { seq: number; item: Item }[] } }
  | { event: "delta"; data: { seq: number; text: string } }
  | { event: "end"; data: { deleted?: boolean } }
  | { event: "reconnect"; data: Record<string, never> };

/** A message for the assistant: the text, files as text, images as data URLs; and where the
 *  user is (the page, the year they look at, their language and day). */
export interface ChatInput {
  text?: string;
  attachments?: ({ kind: "image"; name: string; url: string } | { kind: "file"; name: string; text: string })[];
  page: string;
  year: number;
  lang: "en" | "de";
  today: string;
}

/** A request whose answer is a stream of server-sent events. */
async function stream<E>(method: string, path: string, body: unknown, onEvent: (e: E) => void, signal?: AbortSignal) {
  let res: Response;
  try {
    res = await fetch(path, {
      method,
      credentials: "same-origin",
      cache: "no-store",
      headers: body !== undefined ? { "content-type": "application/json" } : {},
      body: body !== undefined ? JSON.stringify(body) : undefined,
      signal,
    });
  } catch (err) {
    if ((err as Error).name === "AbortError") return;
    throw new ApiError((err as Error).message || "Network error", 0);
  }
  if (!res.ok || !res.body) {
    const data = await res.json().catch(() => ({}));
    throw new ApiError(data.error || `HTTP ${res.status}`, res.status);
  }
  const reader = res.body.pipeThrough(new TextDecoderStream()).getReader();
  let buffer = "";
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += value;
      let end: number;
      while ((end = buffer.indexOf("\n\n")) >= 0) {
        const block = buffer.slice(0, end);
        buffer = buffer.slice(end + 2);
        const event = /^event: (.*)$/m.exec(block)?.[1];
        const data = /^data: (.*)$/m.exec(block)?.[1];
        if (!event || data === undefined || event === "ping") continue;
        onEvent({ event, data: JSON.parse(data) } as E);
      }
    }
  } catch (err) {
    if ((err as Error).name === "AbortError") return;
    throw new ApiError((err as Error).message, 0);
  }
}

export const aiApi = {
  settings: (familyId: string) => request<AiSettings>("GET", `${fam(familyId)}/ai/settings`),
  saveSettings: (familyId: string, patch: AiSettingsPatch) =>
    request<AiSettings>("PUT", `${fam(familyId)}/ai/settings`, patch),
  models: (familyId: string, body: { baseUrl?: string; apiKey?: string } = {}) =>
    request<{ models: string[] }>("POST", `${fam(familyId)}/ai/models`, body),
  test: (familyId: string) =>
    request<{ ok: boolean; model: string; reply: string }>("POST", `${fam(familyId)}/ai/test`, {}),
  /** Sorts uncategorized transactions (the given ids, or those of a range) like similar ones,
   *  and the rest with the AI if it is set up. */
  categorize: (
    familyId: string,
    body: { ids?: string[]; from?: string; to?: string; skip?: number; lang?: "en" | "de" },
  ) => request<CategorizeResult>("POST", `${fam(familyId)}/ai/categorize`, body),
  /** Runs undo steps in order (they are relative to the family). */
  undo: async (familyId: string, steps: UndoStep[]) => {
    for (const step of steps) await request(step.method, fam(familyId) + step.path, step.body);
  },
  chats: (familyId: string) =>
    request<{ chats: ChatSummary[] }>("GET", `${fam(familyId)}/ai/chats`).then((r) => r.chats),
  chat: <Item>(familyId: string, id: string) =>
    request<ChatState<Item>>("GET", `${fam(familyId)}/ai/chats/${enc(id)}`),
  /** Starts a chat with its first message; streams it like followChat. */
  startChat: <Item>(familyId: string, input: ChatInput, onEvent: (e: ChatEvent<Item>) => void, signal?: AbortSignal) =>
    stream("POST", `${fam(familyId)}/ai/chats`, input, onEvent, signal),
  sendMessage: <Item>(
    familyId: string,
    id: string,
    input: ChatInput,
    onEvent: (e: ChatEvent<Item>) => void,
    signal?: AbortSignal,
  ) => stream("POST", `${fam(familyId)}/ai/chats/${enc(id)}/messages`, input, onEvent, signal),
  /** A message while a turn runs: it waits on the server and goes next (follow the chat). */
  queueMessage: (familyId: string, id: string, input: ChatInput) =>
    request<{ chat: ChatSummary; id: string }>("POST", `${fam(familyId)}/ai/chats/${enc(id)}/queue`, input),
  unqueueMessage: (familyId: string, id: string, entry: string) =>
    request<{ chat: ChatSummary }>("POST", `${fam(familyId)}/ai/chats/${enc(id)}/unqueue`, { id: entry }),
  answerQuestion: <Item>(
    familyId: string,
    id: string,
    answer: Omit<ChatInput, "text" | "attachments"> & { id: string; selected: string[]; text?: string },
    onEvent: (e: ChatEvent<Item>) => void,
    signal?: AbortSignal,
  ) => stream("POST", `${fam(familyId)}/ai/chats/${enc(id)}/answer`, answer, onEvent, signal),
  /** Follows a chat: what changed since revision `since`, until no turn runs. */
  followChat: <Item>(
    familyId: string,
    id: string,
    since: number,
    onEvent: (e: ChatEvent<Item>) => void,
    signal?: AbortSignal,
  ) => stream("GET", `${fam(familyId)}/ai/chats/${enc(id)}/events?since=${since}`, undefined, onEvent, signal),
  /** Moves a chat to another page. */
  moveChat: (familyId: string, id: string, page: string) =>
    request<{ chat: ChatSummary }>("POST", `${fam(familyId)}/ai/chats/${enc(id)}/page`, { page }),
  stopChat: (familyId: string, id: string) => request<unknown>("POST", `${fam(familyId)}/ai/chats/${enc(id)}/stop`, {}),
  deleteChat: (familyId: string, id: string) => request<unknown>("DELETE", `${fam(familyId)}/ai/chats/${enc(id)}`),
  /** Tells the chat that its change `changeId` was undone. */
  chatUndone: (familyId: string, id: string, changeId: string) =>
    request<unknown>("POST", `${fam(familyId)}/ai/chats/${enc(id)}/undone`, { id: changeId }),
};
