// What the model gets of a long chat: everything, until it would no longer fit into the model's
// context window. Then the older part is condensed into a summary (by the model itself), which
// is kept with the chat's messages, and the model gets the summary plus the newer messages. So a
// turn can run on and on, and the next one still knows what happened before.

import { HttpError } from "@/lib/api/http";
import type { NetOptions } from "./net";
import { type ChatMessage, type ContentPart, type Provider, streamChat } from "./provider";

/** Tokens a model takes when the endpoint doesn't say (and no window is set). */
export const DEFAULT_WINDOW = 128_000;
/** The share of the window a request may fill before the older messages are condensed (the
 *  rest is left for the answer, and for estimates that fall short). */
export const COMPACT_AT = 0.75;
/** The share of the room for messages that the newest keep after condensing. */
export const KEEP = 0.4;
/** Roughly what an image costs. */
const IMAGE_TOKENS = 1000;
/** Characters per token, a little on the safe side (JSON and German take more tokens). */
const CHARS_PER_TOKEN = 3.5;
/** Characters of a tool's arguments or result the summary gets to see. */
const MAX_FOLD_TEXT = 40_000;
const MAX_IMAGES = 8;
const OLD_IMAGE = "(an earlier image, no longer sent)";

/** Stored among a chat's messages: the summary of the ones before `from` (the messages from
 *  there on follow it); `request`, the user's latest message if it is among those condensed. */
export interface SummaryMark {
  role: "summary";
  content: string;
  request?: ChatMessage["content"];
  from: number;
  tool_calls?: undefined;
  tool_call_id?: undefined;
}

/** A chat's messages as stored: the model's messages and the summaries. */
export type StoredMessage = ChatMessage | SummaryMark;

/** A summary as the model gets it: a message of the user, with their latest request. */
export function summaryMessage(s: Pick<SummaryMark, "content" | "request">): ChatMessage {
  const head = `[What happened earlier in this chat, condensed because the conversation got too ` +
    `long to send in full:]\n\n${s.content}`;
  if (s.request === undefined || s.request === null) return { role: "user", content: head };
  const tail = "\n\n[The user's latest message, which you are working on:]\n";
  if (!Array.isArray(s.request)) return { role: "user", content: head + tail + s.request };
  return { role: "user", content: [{ type: "text", text: head + tail }, ...s.request] };
}

/** What the model gets of a chat's messages: the latest summary and the messages after it (or
 *  all of them), starting with a message of the user, and only the newest images. */
export function viewOf(stored: StoredMessage[]): ChatMessage[] {
  const at = stored.findLastIndex((m) => m.role === "summary");
  const plain = (list: StoredMessage[]) =>
    list.filter((m): m is ChatMessage => m.role !== "summary");
  let out: ChatMessage[];
  if (at < 0) {
    out = plain(stored);
    while (out.length && out[0].role !== "user") out.shift();
  } else {
    const mark = stored[at] as SummaryMark;
    out = [summaryMessage(mark), ...plain(stored.slice(mark.from))];
  }
  let images = 0;
  for (let i = out.length - 1; i >= 0; i--) {
    const m = out[i];
    if (!Array.isArray(m.content)) continue;
    out[i] = {
      ...m,
      content: m.content.map((p): ContentPart =>
        p.type === "image_url" && ++images > MAX_IMAGES ? { type: "text", text: OLD_IMAGE } : p
      ),
    };
  }
  return out;
}

/** Roughly how many tokens `messages` (and the tools' descriptions) take. */
export function estimateTokens(messages: ChatMessage[], tools?: unknown[]): number {
  let chars = tools?.length ? JSON.stringify(tools).length : 0;
  let images = 0;
  for (const m of messages) {
    chars += 12;
    if (typeof m.content === "string") chars += m.content.length;
    else if (Array.isArray(m.content)) {
      for (const p of m.content) {
        if (p.type === "text") chars += p.text.length;
        else images++;
      }
    }
    if (m.tool_calls) chars += JSON.stringify(m.tool_calls).length;
  }
  return Math.ceil(chars / CHARS_PER_TOKEN) + images * IMAGE_TOKENS;
}

/** The endpoint refused a request because it doesn't fit into the model's context. */
export function isContextError(err: unknown): boolean {
  const message = err instanceof Error ? err.message : String(err);
  return /context[ _-]?(length|window|size)|maximum context|too many tokens|token limit|prompt is too long|input is too long|reduce the length|exceeds? the (model'?s? )?(maximum|max|limit)/i
    .test(message);
}

/** The context window an endpoint's error names ("maximum context length is 8192 tokens"). */
export function windowFromError(err: unknown): number | null {
  const message = err instanceof Error ? err.message : String(err);
  const m =
    /(?:context length|context window|context size|maximum|limit)[^\d]{0,30}(\d[\d,.]*)\s*tokens/i
      .exec(message);
  const n = m ? Number(m[1].replace(/[,.]/g, "")) : NaN;
  return Number.isInteger(n) && n >= 1000 ? n : null;
}

const SUMMARIZE = `You condense a conversation between a user and the AI assistant of a family
app (a vacation calendar, the family's finances, meals and doctor appointments). The assistant will go on working
with only your summary and the newest messages, so keep everything it needs:
- what the user asked for, wants and decided (also their answers to the assistant's questions),
  close to their own words where it matters;
- what the assistant found out, with the concrete facts: dates, amounts, ids, names, sources;
- what the assistant changed (and what the user undid);
- the task at hand: what is done, what is still open, the next steps it planned.
Leave out what no longer matters (small talk, failed attempts that taught nothing). Write in the
language of the conversation, as short Markdown lists, at most about 1500 words. Answer with the
summary only.`;

/** A message as text for the summary. */
function lineOf(m: ChatMessage, names: Map<string, string>): string {
  const cut = (s: string) =>
    s.length > MAX_FOLD_TEXT ? s.slice(0, MAX_FOLD_TEXT) + "…(truncated)" : s;
  const text = Array.isArray(m.content)
    ? m.content.map((p) => (p.type === "text" ? p.text : "(an image)")).join("\n")
    : m.content ?? "";
  if (m.role === "tool") {
    return `Result of ${names.get(m.tool_call_id ?? "") ?? "a tool"}: ${cut(text)}`;
  }
  if (m.role === "user") return `User: ${text}`;
  const calls = (m.tool_calls ?? []).map((c) => {
    names.set(c.id, c.function.name);
    return `Assistant calls ${c.function.name} ${cut(c.function.arguments)}`;
  });
  return [text && `Assistant: ${text}`, ...calls].filter(Boolean).join("\n");
}

export interface Compacted {
  /** The summary as stored (without `from`, which the chat knows). */
  mark: Pick<SummaryMark, "content" | "request">;
  /** How many of the messages stay as they are (the newest). */
  keep: number;
}

/**
 * Condenses the older part of `messages` (the model's messages after the instructions, the
 * first one the current summary if `summarized`) so that the rest takes at most `room` tokens.
 * Returns null when there is nothing to condense. The newest messages are kept from a message
 * of the user or the assistant on (never from a tool result, which needs its call before it).
 */
export async function compact(opts: {
  provider: Provider;
  net: NetOptions;
  signal?: AbortSignal;
  messages: ChatMessage[];
  /** The summary the messages start with, if any. */
  summary: SummaryMark | Pick<SummaryMark, "content" | "request"> | null;
  /** Tokens the newest messages may take. */
  room: number;
  /** Tokens of conversation per call of the model. */
  chunk: number;
}): Promise<Compacted | null> {
  const { messages, summary } = opts;
  const first = summary ? 1 : 0;
  // Keep as many of the newest messages as fit.
  let k = messages.length;
  let size = 0;
  for (let i = messages.length - 1; i >= first; i--) {
    size += estimateTokens([messages[i]]);
    if (size > opts.room) break;
    if (messages[i].role !== "tool") k = i;
  }
  if (k <= first) return null;
  const folded = messages.slice(first, k);
  // The user's latest message stays word for word.
  const u = messages.findLastIndex((m, i) => i >= first && m.role === "user");
  const request = u >= k ? undefined : u >= first ? messages[u].content : summary?.request;

  const names = new Map<string, string>();
  const lines = folded.map((m) => lineOf(m, names));
  const max = Math.max(4000, Math.floor(opts.chunk * CHARS_PER_TOKEN));
  let text = summary?.content ?? "";
  for (let i = 0; i < lines.length;) {
    let part = "";
    while (i < lines.length && (!part || part.length + lines[i].length < max)) {
      part += (part ? "\n\n" : "") + lines[i].slice(0, max);
      i++;
    }
    text = await condense(opts, text, part);
  }
  return {
    mark: { content: text, ...(request !== undefined ? { request } : {}) },
    keep: messages.length - k,
  };
}

async function condense(
  opts: { provider: Provider; net: NetOptions; signal?: AbortSignal },
  before: string,
  part: string,
): Promise<string> {
  const input = (before ? `## Summary so far\n${before}\n\n## What happened next\n` : "") + part;
  let out = "";
  for await (
    const ev of streamChat(
      opts.provider,
      {
        messages: [
          { role: "system", content: SUMMARIZE },
          { role: "user", content: input },
        ],
      },
      opts.net,
      opts.signal,
    )
  ) {
    if (ev.type === "done") out = ev.content;
  }
  out = out.trim();
  if (!out) throw new HttpError(502, "The model didn't condense the conversation");
  return out;
}
