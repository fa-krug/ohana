// A client for OpenAI-compatible chat APIs (OpenAI, Azure-style proxies, OpenRouter, Mistral,
// Groq, Ollama, LM Studio, vLLM …): the model list and streamed chat completions with tools.

import { HttpError } from "@/lib/api/http";
import { type NetOptions, readLimited, safeFetch } from "./net";

export interface ToolCall {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
}

/** A piece of a user message: text, or an image as a data URL. */
export type ContentPart =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string } };

export interface ChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string | null | ContentPart[]; // parts only in user messages
  tool_calls?: ToolCall[];
  tool_call_id?: string;
}

export interface ToolSpec {
  type: "function";
  function: { name: string; description: string; parameters: Record<string, unknown> };
}

export interface Provider {
  baseUrl: string; // e.g. https://api.openai.com/v1
  apiKey: string;
  model: string;
}

/** Tokens a model call used, as the endpoint reports them. */
export interface Usage {
  prompt: number;
  completion: number;
}

export type StreamEvent =
  | { type: "text"; delta: string }
  | {
    type: "done";
    content: string;
    toolCalls: ToolCall[];
    finish: string | null;
    /** Only when the endpoint reports it. */
    usage?: Usage;
  };

function headers(p: Provider): Record<string, string> {
  return {
    "content-type": "application/json",
    ...(p.apiKey ? { authorization: `Bearer ${p.apiKey}` } : {}),
  };
}

function endpoint(p: Provider, path: string) {
  return p.baseUrl.replace(/\/+$/, "") + path;
}

async function failure(res: Response, what: string): Promise<HttpError> {
  return errorOf(res.status, await readLimited(res, 4000).catch(() => ""), what);
}

function errorOf(status: number, text: string, what: string): HttpError {
  let message = text.trim().slice(0, 300);
  try {
    const data = JSON.parse(text);
    message = data?.error?.message ?? data?.message ?? data?.error ?? message;
  } catch {
    // not JSON
  }
  return new HttpError(502, `${what}: ${status} ${String(message).slice(0, 300)}`.trim());
}

/** The ids of the models the endpoint offers, sorted. */
export async function listModels(p: Provider, net: NetOptions): Promise<string[]> {
  const res = await safeFetch(
    endpoint(p, "/models"),
    { headers: headers(p), timeoutMs: 15000 },
    net,
  );
  if (!res.ok) throw await failure(res, "The AI endpoint refused the model list");
  let data: { data?: { id?: unknown }[]; models?: { id?: unknown; name?: unknown }[] };
  try {
    data = JSON.parse(await readLimited(res, 2_000_000));
  } catch {
    throw new HttpError(502, "The AI endpoint didn't answer with a model list");
  }
  const list = data.data ?? data.models ?? [];
  return [...new Set(list.map((m) => String(m.id ?? (m as { name?: unknown }).name ?? "")))]
    .filter(Boolean).sort();
}

/** The model entry's context window, under the names endpoints use for it. */
function windowOf(m: Record<string, any>): number | null {
  for (
    const v of [
      m.context_length,
      m.context_window,
      m.max_context_length,
      m.max_model_len,
      m.top_provider?.context_length,
      m.limits?.max_context_window_tokens,
    ]
  ) {
    const n = Number(v);
    if (Number.isInteger(n) && n >= 1000) return n;
  }
  return null;
}

/** Context windows by endpoint and model, found out before (null: the endpoint doesn't say). */
const windows = new Map<string, { value: number | null; until: number }>();

/** How many tokens the model takes, if the endpoint's model list says (OpenRouter, Groq,
 *  Mistral, LM Studio, vLLM … do; OpenAI doesn't). Remembered for an hour. */
export async function contextWindow(p: Provider, net: NetOptions): Promise<number | null> {
  const key = `${p.baseUrl} ${p.model}`;
  const known = windows.get(key);
  if (known && known.until > Date.now()) return known.value;
  let value: number | null = null;
  try {
    const res = await safeFetch(
      endpoint(p, "/models"),
      { headers: headers(p), timeoutMs: 10000 },
      net,
    );
    if (res.ok) {
      const data = JSON.parse(await readLimited(res, 4_000_000));
      const list: Record<string, any>[] = data?.data ?? data?.models ?? [];
      const entry = list.find((m) => m && (m.id ?? m.name) === p.model);
      if (entry) value = windowOf(entry);
    } else await res.body?.cancel();
  } catch {
    // The endpoint doesn't say: the default applies.
  }
  windows.set(key, { value, until: Date.now() + 3_600_000 });
  return value;
}

/** Endpoints that refused to report the tokens of a streamed answer (stream_options). */
const noUsage = new Set<string>();

function usageOf(u: any): Usage | undefined {
  const prompt = Number(u?.prompt_tokens);
  if (!Number.isFinite(prompt) || prompt <= 0) return undefined;
  const completion = Number(u?.completion_tokens);
  return { prompt, completion: Number.isFinite(completion) ? completion : 0 };
}

/**
 * One chat completion, streamed: yields text as it arrives, then the whole message with its
 * tool calls (and the tokens used, if the endpoint says). Servers that don't stream (they answer
 * with JSON) work too.
 */
export async function* streamChat(
  p: Provider,
  body: {
    messages: ChatMessage[];
    tools?: ToolSpec[];
    /** "none" keeps the tools known but has the model answer (default "auto"). */
    toolChoice?: "auto" | "none";
    temperature?: number;
  },
  net: NetOptions,
  signal?: AbortSignal,
): AsyncGenerator<StreamEvent> {
  const post = (usage: boolean) =>
    safeFetch(endpoint(p, "/chat/completions"), {
      method: "POST",
      headers: headers(p),
      body: JSON.stringify({
        model: p.model,
        messages: body.messages,
        ...(body.tools?.length
          ? { tools: body.tools, tool_choice: body.toolChoice ?? "auto" }
          : {}),
        ...(body.temperature !== undefined ? { temperature: body.temperature } : {}),
        stream: true,
        // The tokens used come with the last chunk (how full the context is).
        ...(usage ? { stream_options: { include_usage: true } } : {}),
      }),
      signal,
      timeoutMs: 120000,
    }, net);
  const asked = !noUsage.has(p.baseUrl);
  let res = await post(asked);
  if (!res.ok && asked && (res.status === 400 || res.status === 422)) {
    const text = await readLimited(res, 4000).catch(() => "");
    if (!/stream_options|include_usage/i.test(text)) {
      throw errorOf(res.status, text, "The AI endpoint refused the request");
    }
    // An endpoint that doesn't know the option: asked without it from now on.
    noUsage.add(p.baseUrl);
    res = await post(false);
  }
  if (!res.ok) throw await failure(res, "The AI endpoint refused the request");

  const type = res.headers.get("content-type") ?? "";
  if (!type.includes("text/event-stream")) {
    // No streaming: one JSON answer.
    const data = JSON.parse(await readLimited(res, 4_000_000));
    const message = data?.choices?.[0]?.message ?? {};
    const content = typeof message.content === "string" ? message.content : "";
    if (content) yield { type: "text", delta: content };
    yield {
      type: "done",
      content,
      toolCalls: (message.tool_calls ?? []).map(normalizeCall),
      finish: data?.choices?.[0]?.finish_reason ?? null,
      usage: usageOf(data?.usage),
    };
    return;
  }

  let content = "";
  let finish: string | null = null;
  let usage: Usage | undefined;
  const calls: ToolCall[] = [];
  const reader = res.body!.pipeThrough(new TextDecoderStream()).getReader();
  let buffer = "";
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += value;
      let nl: number;
      while ((nl = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (payload === "[DONE]") continue;
        let chunk;
        try {
          chunk = JSON.parse(payload);
        } catch {
          continue;
        }
        if (chunk.error) {
          throw new HttpError(502, `The AI endpoint failed: ${chunk.error.message ?? chunk.error}`);
        }
        usage = usageOf(chunk.usage) ?? usage;
        const choice = chunk.choices?.[0];
        if (!choice) continue;
        if (choice.finish_reason) finish = choice.finish_reason;
        const delta = choice.delta ?? {};
        if (typeof delta.content === "string" && delta.content) {
          content += delta.content;
          yield { type: "text", delta: delta.content };
        }
        for (const tc of delta.tool_calls ?? []) {
          const i = typeof tc.index === "number" ? tc.index : calls.length;
          calls[i] ??= { id: "", type: "function", function: { name: "", arguments: "" } };
          if (tc.id) calls[i].id = tc.id;
          if (tc.function?.name) calls[i].function.name += tc.function.name;
          if (tc.function?.arguments) calls[i].function.arguments += tc.function.arguments;
        }
      }
    }
  } finally {
    reader.releaseLock();
  }
  yield {
    type: "done",
    content,
    toolCalls: calls.filter(Boolean).map(normalizeCall),
    finish,
    usage,
  };
}

let callSeq = 0;

function normalizeCall(
  c: Partial<ToolCall> & { function?: Partial<ToolCall["function"]> },
): ToolCall {
  const args = c.function?.arguments as unknown;
  return {
    id: c.id || `call_${Date.now().toString(36)}_${callSeq++}`,
    type: "function",
    function: {
      name: c.function?.name ?? "",
      // Some servers send the arguments as an object instead of a JSON string.
      arguments: typeof args === "string" ? args : JSON.stringify(args ?? {}),
    },
  };
}
