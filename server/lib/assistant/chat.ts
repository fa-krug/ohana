// One chat turn: the system prompt and the tool loop against the family's AI endpoint, which
// reports what it does as events (chats.ts keeps them as the chat's items and messages; the
// follow route streams them to the app as server-sent events).

import { HttpError, objectOf } from "@/lib/api/http";
import { formatDate, isValidDate } from "@/lib/calendar/dates";
import type { FamilyRow, TypeRow } from "@/lib/calendar/store";
import { categoryTree } from "@/lib/finance/category-tree";
import type { AccountRow, Benchmark, CategoryRow } from "@/lib/finance/store";
import {
  compact,
  COMPACT_AT,
  estimateTokens,
  isContextError,
  KEEP,
  type SummaryMark,
  summaryMessage,
  windowFromError,
} from "./context";
import { ageOn } from "@/lib/families/birthdays";
import type { NetOptions } from "./net";
import {
  type ChatMessage,
  type ContentPart,
  type Provider,
  streamChat,
  type ToolCall,
} from "./provider";
import {
  MAX_TOOL_RESULT,
  type Question,
  readsOnly,
  runTool,
  type ToolContext,
  toolsFor,
} from "./tools";

/** Messages of a history the caller keeps (POST /ai/chat); stored chats are condensed instead
 *  (see context.ts). */
const MAX_MESSAGES = 80;
const MAX_CONTENT = 20_000;
/** Attachments: parts per message, an attached file's text, images per message and per chat. */
const MAX_PARTS = 10;
const MAX_FILE_TEXT = 60_000;
const MAX_IMAGE_URL = 2_000_000;
const IMAGES_PER_MESSAGE = 4;
const MAX_IMAGES = 8;
const IMAGE_URL = /^data:image\/(png|jpeg|webp|gif);base64,[A-Za-z0-9+/=]+$/;
const OLD_IMAGE = "(an earlier image, no longer sent)";
/** After this, a turn hands itself on ("continue"): in family-planner to a new Edge Function
 *  invocation; the worker has no time limit and passes Infinity (it only starts over). */
export const HAND_OFF_MS = 90_000;
/** A model call that is still running then is cut off (Infinity in the worker: only the
 *  model call's own timeout applies). */
export const DEADLINE_MS = 130_000;
const MODEL_TIMEOUT_MS = 120_000;
const NO_ANSWER = "(The model gave no answer.)";
const TOO_SLOW = "The AI model took too long to answer.";
/** Times a model that ended without a word is asked again for its answer. */
const MAX_NUDGES = 5;
/** A request that still has to condense the conversation after this long hands it on first, so
 *  condensing gets a new request's whole time. */
const LATE_COMPACT_MS = 30_000;
const CONTEXT_FULL =
  "The conversation doesn't fit into the model's context window, even condensed. Start a new chat, or pick a model with a larger one.";

/** For a model that ended its turn without a word: it gets one more call, without tools. */
const ANSWER_NOW = `

## Answer now
You ended without answering. Don't use tools now: tell the user what you found and did.`;

export type Emit = (event: string, data: unknown) => void;

/** The pages a chat can belong to: Ohana's modules, the family overview and the settings. */
export const PAGES = ["overview", "calendar", "finance", "meals", "appointments", "settings"];
/** family-planner's names of pages (its chats may come with them). */
const OLD_PAGES: Record<string, string> = { vacation: "calendar" };

/** A page by its name (or family-planner's); null for an unknown one. */
export function cleanPage(v: unknown): string | null {
  const page = typeof v === "string" ? (OLD_PAGES[v] ?? v) : "";
  return PAGES.includes(page) ? page : null;
}

/** What the instructions depend on, from the app's latest message: the page and year the user
 *  looks at, their language and their day. */
export interface ChatContext {
  page: string;
  year: number;
  lang: "en" | "de";
  today: string;
}

/** The context the app sent, checked; the server's day (and its year) as a fallback. */
export function cleanContext(body: Record<string, unknown>): ChatContext {
  const today = isValidDate(body.today) ? body.today as string : formatDate(new Date());
  return {
    page: cleanPage(body.page) ?? "overview",
    year: Number.isInteger(body.year) ? body.year as number : Number(today.slice(0, 4)),
    lang: body.lang === "de" ? "de" : "en",
    today,
  };
}

/** What each page shows, and what the user most likely means there. */
const PAGE_FOCUS = (year: number): Record<string, string> => ({
  overview: `the family's overview: a card per module (calendar, finances, meals, doctor
appointments). Requests can be about any of them.`,
  calendar: `the vacation calendar of ${year}: entries, entry types, day notes and coverage
gaps. Read requests as being about the calendar, and keep suggestions, options and next steps
about it (vacations, days off, covering gaps); bring up the finances only when asked.`,
  finance: `the finances: transactions, categories, accounts, spending and income. Read requests
as being about the finances, and keep suggestions, options and next steps about them
(categorizing, budgets, spending, transfers, balances); don't suggest calendar entries or bring
up the calendar unless the user asks for it.`,
  meals: `the meals: the recipes, the meal plan (lunch per day) and the shopping lists. Read
requests as being about the meals, and keep suggestions, options and next steps about them
(recipes to try, planning the next weeks, the shopping list).`,
  appointments: `the doctor appointment searches (Doctolib, jameda): watchers that look for free
slots regularly, the slots they found, and booked appointments. Read requests as being about
them, and keep suggestions, options and next steps about them (a new search, an earlier slot,
booking).`,
  settings: `the settings: the family's name, members and sharing, the year's entry types,
the finance categories and accounts, and the AI. Read requests as being about these settings,
and keep suggestions, options and next steps about them.`,
});

const LANGUAGES: Record<string, string> = { en: "English", de: "German (Deutsch)" };
const ROLE_TEXT: Record<string, string> = {
  needs_cover: "needs cover",
  covers: "covers",
  day_off: "day off",
  none: "normal",
};

function peopleText(people: { name: string; account: boolean; birthday: string | null }[], today: string): string {
  if (!people.length) return "(unknown)";
  return people
    .map((p) => {
      const about = [
        p.account ? "" : "no account, e.g. a child",
        p.birthday ? `born ${p.birthday}, ${ageOn(p.birthday, today)} years old` : "",
      ].filter(Boolean);
      return about.length ? `${p.name} (${about.join("; ")})` : p.name;
    })
    .join(", ");
}

export function systemPrompt(input: {
  family: FamilyRow;
  types: TypeRow[];
  categories: CategoryRow[];
  accounts: AccountRow[];
  currency: string;
  benchmark?: Benchmark | null;
  today: string;
  year: number;
  page: string;
  lang: string;
  writes: boolean;
  /** The family's meal tags (names, in the user's language). */
  mealTags?: string;
  /** The family's home address, if set (appointment searches look around it). */
  home?: string | null;
  /** The family's members by name; `account: false` for those who don't sign in (children …). */
  people?: { name: string; account: boolean; birthday: string | null }[];
  /** Why the assistant can only read: the settings, or the user is a viewer of the family. */
  readOnly?: "settings" | "viewer";
  search: boolean;
}): string {
  const { family, today, year } = input;
  const weekday = new Date(today + "T00:00:00Z").toLocaleDateString("en", {
    weekday: "long",
    timeZone: "UTC",
  });
  const types = input.types.filter((t) => t.year === year);
  const typeList = types.length
    ? types.map((t) => `- ${t.id}: “${t.name}” (${ROLE_TEXT[t.role]})`).join("\n")
    : "- (none yet)";
  const tree = categoryTree(input.categories);
  const cats = input.categories.length
    ? tree.ordered.map((c) => `${c.id} (“${tree.path(c.id)}”, ${c.kind})`).join(", ")
    : "(none)";
  const accounts = input.accounts.length
    ? input.accounts.map((a) => `${a.id} (“${a.name}”)`).join(", ")
    : "(none)";
  const b = input.benchmark;
  const benchmark = b
    ? `${b.label ? `“${b.label}”: ` : ""}${
      JSON.stringify({ income: b.income, expense: b.expense, categories: b.categories })
    }`
    : "not set";
  return `You are the assistant inside Ohana, the family app of the family “${family.name}”.
Today is ${today} (${weekday}). This chat belongs to the ${input.page} page; the calendar
year is ${year}.
Answer in ${LANGUAGES[input.lang] ?? "the user's language"}, briefly and friendly.
The family's members: ${peopleText(input.people ?? [], today)}. Use their names as the "person" of
events and booked appointments ("for Mia"); don't make up others.

## This chat's page
This chat belongs to the ${input.page} page, which shows ${PAGE_FOCUS(year)[input.page]}
If earlier messages were about another page, the user moved the chat here: answer the newest
message for this page unless it clearly continues the earlier topic.

## Vacation calendar
A year calendar where each day can hold several entries of entry types; every year has its own
types. Roles drive the coverage check: a weekday with a "needs cover" entry (e.g. day care
closed) is a gap unless it also has a "covers" (e.g. a parent's vacation) or "day off" entry
(e.g. a public holiday). Days can also have one note (emoji icon and/or comment).
Entry types in ${year}:
${typeList}

## Finances
A transactions log in ${input.currency}. Amounts in tools are integer cents, negative for money
going out (-4599 = −45.99). Categories: ${cats}. Accounts: ${accounts}.
Categories nest to any depth (“Food > Groceries”): a transaction can be on any level, and a
category's totals and filters include its subcategories.
The overview compares the chosen month, year or all time (per month) with others, and shows
where it is within the ranges of a statistic average per month the family sets
(set_statistic_average), currently: ${benchmark}.
Transactions on different accounts that are one transfer between the family's own accounts
(500 out of checking, 500 into savings) are linked as a transfer (same transferId); totals count
a transfer once by its net, so moving money between accounts counts nothing.

## Calendar events
Besides entries, days can hold events: appointments with a time, place and person (e.g. a
booked doctor's appointment), trips, classes. They don't count for coverage. An event lasts
one day or several (date to endDate), all day (no start) or at a time (end is the time on
endDate), and may repeat: rrule is an RFC 5545 RRULE value such as "FREQ=WEEKLY;BYDAY=MO,WE",
"FREQ=MONTHLY;BYDAY=-1FR" or "FREQ=YEARLY;COUNT=3" (UNTIL is a date YYYYMMDD). list_events
lists occurrences; a repeating event's occurrence is its id plus its original date
(occurrence). To change or remove one occurrence use update_event / remove_event with
occurrence and span "this"; "future" for this and the following ones, "all" for the series.

## Meals
Recipes (KNOWN: the family's own; TO_TRY: want to try) with ingredients, steps and tags. The
meal plan plans a lunch per day in iterations of 1–3 weeks, with leftovers on later days and
nothing on days the family is away (calendar types marked "away"); each iteration has shopping
lists for its shopping days. Tags: ${input.mealTags || "(none)"}.
"Plan next week without fish": plan_meals with action "next" and excludeTags ["Fish"] (check
with get_meal_plan which days the next iteration covers; "again" plans an existing one anew).

## Doctor appointments
Appointment searches watch Doctolib and jameda for free slots of a speciality near a place up to
a number of days ahead and notify the family; Ohana can't book: the user books with the
practice (the slot's bookingUrl), then book_appointment_slot marks it as booked in the calendar.
"Find a dermatologist before June": create_appointment_search with speciality "Hautarzt" and
before the last day of May (the next May from today). The family's home address: ${
    input.home ? `“${input.home}”` : "not set (searches then need a place)"
  }.

## How to work
- Use the tools to look things up; don't guess what's in the calendar, the finances, the meals
  or the appointment searches.
- Don't add up or work out numbers yourself: analyze_transactions and analyze_calendar give
  totals, averages and counts per month, category, payee, type …; calculate does any other
  math (percentages, statistics, trends, loans and savings).
${
    input.writes
      ? `- Read before you change. Make small, clearly requested changes directly. Before bigger
  ones (more than 31 days, deleting types or categories, deleting or many transactions) say
  what you'll do and ask for the OK with ask_user; the tools refuse until you call them again
  with "confirmed": true after the user agreed.
- If a fitting category is missing, you can add it with manage_categories, also as a
  subcategory, and nest or move categories there.
- After a change, say in one sentence what changed. The user can undo it in the chat.`
      : input.readOnly === "viewer"
      ? "- You can only read: the user can only view this family, not change it."
      : "- You can only read: changing anything is switched off in the settings."
  }
${
    input.search
      ? "- For facts from the web (school and public holidays, opening times, prices), search, read the best sources with fetch_page, and name them."
      : "- Web search isn't set up; you can still read pages with fetch_page when the user gives a URL."
  }
- Work in few steps: first think which numbers the answer needs, then get them together.
  One analyze_transactions call groups by up to two dimensions (e.g. year and category, so
  every category at once) and takes several queries (periods, accounts, filters) at once:
  don't call it once per category, account or period. Put all the math into one calculate
  call. Call tools that don't depend on each other in the same step, and put many changes
  into one call's ops.
- Dates are YYYY-MM-DD. Keep answers short; use Markdown lists or tables only where they help.

## Ask instead of guessing
Asking is cheap for the user: ask_user shows answers to click (one, or several with
multiple: true), and they can always write their own. So ask whenever an answer depends on
something only the user knows, rather than picking for them or asking in plain text:
- The request is ambiguous: which person, entry type, account or category; which of several
  matching days or transactions; which year or period.
- There are real options to choose from: several free weeks for a vacation, ways to cover a
  gap, categories that could fit, what to do with duplicates.
- A detail is missing for a change: half or whole days, weekends or not, an amount, a name.
- You found something on the way the user may want handled (more gaps, uncategorized rows):
  offer the next steps as options, about what this chat's page shows.
- You need the OK for a bigger change: options like "Yes, do it" / "No".
Look things up with the tools first, so the options are concrete (real dates, names,
amounts). Don't ask what the tools can tell you, or when the request is already clear.`;
}

/** Where the window of a history starts: the newest MAX_MESSAGES messages, but all of the
 *  current turn (from the user's latest message). */
function windowStart(list: unknown[]): number {
  const turn = list.findLastIndex((m) => (m as { role?: unknown } | null)?.role === "user");
  return Math.max(
    0,
    turn < 0 ? list.length - MAX_MESSAGES : Math.min(list.length - MAX_MESSAGES, turn),
  );
}

/** The messages the model gets of a (checked) history: its window, cut to a clean start (the
 *  user's message first, no orphaned tool results), with only the newest images. */
export function windowHistory(history: ChatMessage[]): ChatMessage[] {
  const out = history.slice(windowStart(history));
  while (out.length && out[0].role !== "user") out.shift();
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

/** The app's history, checked: user, assistant and tool messages, newest kept (but all of the
 *  current turn). It ends with the user's message, or with tool results to `cont`inue a turn. */
export function cleanHistory(raw: unknown, cont = false): ChatMessage[] {
  if (!Array.isArray(raw) || !raw.length) {
    throw new HttpError(400, "messages must be a non-empty array");
  }
  const out = windowHistory(raw.slice(windowStart(raw)).map(cleanMessage));
  if (cont && out.at(-1)?.role !== "tool") {
    throw new HttpError(400, "To continue, the last message must be a tool result");
  }
  if (!cont && (!out.length || out.at(-1)!.role !== "user")) {
    throw new HttpError(400, "The last message must be the user's");
  }
  return out;
}

/** One message of a history, checked. */
export function cleanMessage(m: unknown): ChatMessage {
  const o = objectOf(m, "Each message");
  if (!["user", "assistant", "tool"].includes(o.role as string)) {
    throw new HttpError(400, "role must be user, assistant or tool");
  }
  let content: ChatMessage["content"];
  if (Array.isArray(o.content)) {
    if (o.role !== "user") throw new HttpError(400, "Only user messages can have parts");
    content = cleanParts(o.content);
  } else {
    content = o.content === null || o.content === undefined ? null : String(o.content);
    if (content && content.length > MAX_CONTENT) {
      throw new HttpError(400, "A message is too long");
    }
  }
  const msg: ChatMessage = { role: o.role as ChatMessage["role"], content };
  if (o.role === "assistant" && Array.isArray(o.tool_calls) && o.tool_calls.length) {
    msg.tool_calls = o.tool_calls.slice(0, 20).map((c) => {
      const call = objectOf(c, "tool call");
      const fn = objectOf(call.function, "tool call function");
      return {
        id: String(call.id ?? ""),
        type: "function" as const,
        function: { name: String(fn.name ?? ""), arguments: String(fn.arguments ?? "{}") },
      };
    });
  }
  if (o.role === "tool") msg.tool_call_id = String(o.tool_call_id ?? "");
  return msg;
}

/** A user message's parts: text (typed or an attached file) and images as data URLs. */
export function cleanParts(raw: unknown[]): ContentPart[] {
  if (!raw.length || raw.length > MAX_PARTS) {
    throw new HttpError(400, `A message needs 1 to ${MAX_PARTS} parts`);
  }
  const parts = raw.map((r): ContentPart => {
    const p = objectOf(r, "Each part");
    if (p.type === "text") {
      if (typeof p.text !== "string") throw new HttpError(400, "A text part needs text");
      if (p.text.length > MAX_FILE_TEXT) throw new HttpError(400, "An attached text is too long");
      return { type: "text", text: p.text };
    }
    if (p.type === "image_url") {
      const url = (p.image_url as { url?: unknown } | null)?.url;
      if (typeof url !== "string" || url.length > MAX_IMAGE_URL || !IMAGE_URL.test(url)) {
        throw new HttpError(400, "An image must be a PNG, JPEG, WebP or GIF data URL (max. 2 MB)");
      }
      return { type: "image_url", image_url: { url } };
    }
    throw new HttpError(400, "A part must be text or image_url");
  });
  if (parts.filter((p) => p.type === "image_url").length > IMAGES_PER_MESSAGE) {
    throw new HttpError(400, `At most ${IMAGES_PER_MESSAGE} images per message`);
  }
  return parts;
}

/**
 * Runs the tool loop, as long as the model works on (there is no limit of steps), and emits:
 * "text" {delta}, "tool" {id, name, args}, "tool_result" {id, name, ok, summary}, "change" {id,
 * kind, summary, undo}, "messages" {messages} (what the app appends to its history, after every
 * step), "question" {id, question, options, multiple} (the model asked the user: the turn ends
 * without the call's result, which the app adds with the answer and then continues), "usage"
 * {used, max} (the tokens of the context in use, and the window), "compacting" {} and
 * "compacted" {summary, request?, keep} (the history got too long for the context window: all but
 * its newest `keep` messages are now the summary, which the caller keeps in their place) and
 * "done" or "continue" {retry?, message?}: time is nearly up, or a model call failed (`retry`,
 * with the reason), so the app sends the history again and the turn goes on there.
 */
export async function runChat(opts: {
  provider: Provider;
  system: string;
  history: ChatMessage[];
  ctx: ToolContext;
  /** Requests to the model; default: the tools' (ctx.net). */
  modelNet?: NetOptions;
  writes: boolean;
  search: boolean;
  emit: Emit;
  signal?: AbortSignal;
  /** When to hand off to a new request (tests). Default: HAND_OFF_MS. */
  handOffMs?: number;
  /** When to cut off a model call (tests). Default: DEADLINE_MS. */
  deadlineMs?: number;
  /** The model's context window in tokens: the history is condensed before it is full. */
  window?: number;
  /** The summary the history starts with (it is the first message). */
  summary?: SummaryMark | null;
}) {
  const { provider, ctx, emit, signal } = opts;
  // The model's endpoint may be allowed where pages aren't (a model on the home network).
  const modelNet = opts.modelNet ?? ctx.net;
  const tools = toolsFor({ writes: opts.writes, search: opts.search });
  const allowed = new Set(tools.map((t) => t.function.name));
  const messages: ChatMessage[] = [{ role: "system", content: opts.system }, ...opts.history];
  const added: ChatMessage[] = [];
  const started = Date.now();
  const handOffMs = opts.handOffMs ?? HAND_OFF_MS;
  const deadlineMs = opts.deadlineMs ?? DEADLINE_MS;
  let late: AbortSignal | undefined;
  const push = (m: ChatMessage) => {
    messages.push(m);
    added.push(m);
  };
  // The app gets each step's messages when it is done, so a request that is cut off loses no
  // more than the step that was running.
  let sent = 0;
  const flush = () => {
    if (added.length > sent) emit("messages", { messages: added.slice(sent) });
    sent = added.length;
  };
  let nudges = 0;
  let window = opts.window;
  let summary: SummaryMark | Pick<SummaryMark, "content" | "request"> | null = opts.summary ??
    null;
  // Estimates of the tokens are scaled by what the endpoint reported for the last request.
  let scale = 1;
  const measure = (list: ChatMessage[]) => Math.round(scale * estimateTokens(list, tools));
  // The endpoint said the context is full: condense before the next try (once).
  let full = false;
  let refused = false;

  const handOff = () => {
    flush();
    emit("continue", {});
  };

  try {
    for (let step = 0;; step++) {
      // Every request takes at least one step, then hands off before time runs out (not while
      // asking for an answer: the history may end with the user's message then).
      if (step > 0 && !nudges && Date.now() - started >= handOffMs) return handOff();
      if (window) {
        const size = measure(messages);
        if (full || size > window * COMPACT_AT) {
          if (step > 0 && Date.now() - started >= Math.min(handOffMs, LATE_COMPACT_MS)) {
            return handOff();
          }
          emit("compacting", {});
          // What the messages may take: the window but the instructions and the tools, and
          // room for the answer.
          const fixed = measure([messages[0]]);
          const room = Math.max(0, window * COMPACT_AT - fixed);
          late = AbortSignal.timeout(
            Math.max(1, Math.min(MODEL_TIMEOUT_MS, deadlineMs - (Date.now() - started))),
          );
          const done = await compact({
            provider,
            net: modelNet,
            signal: signal ? AbortSignal.any([signal, late]) : late,
            messages: messages.slice(1),
            summary,
            room: room * KEEP,
            chunk: Math.max(2000, room),
          });
          late = undefined;
          if (done) {
            summary = done.mark;
            const kept = messages.slice(messages.length - done.keep);
            messages.splice(1, messages.length - 1, summaryMessage(done.mark), ...kept);
            emit("compacted", {
              summary: done.mark.content,
              ...(done.mark.request !== undefined ? { request: done.mark.request } : {}),
              keep: done.keep,
            });
          } else if (full) throw new HttpError(502, CONTEXT_FULL);
          full = false;
        }
        emit("usage", { used: measure(messages), max: window });
      }
      // A model that ended without a word gets no tools, so it answers.
      const final = nudges > 0;
      const body = final
        ? {
          messages: [
            { ...messages[0], content: opts.system + ANSWER_NOW },
            ...messages.slice(1),
          ],
        }
        : { messages };
      let content = "";
      let calls: ToolCall[] = [];
      late = AbortSignal.timeout(
        Math.max(1, Math.min(MODEL_TIMEOUT_MS, deadlineMs - (Date.now() - started))),
      );
      const stream = streamChat(
        provider,
        { ...body, tools, toolChoice: final ? "none" : "auto" },
        modelNet,
        signal ? AbortSignal.any([signal, late]) : late,
      );
      let usage: { prompt: number; completion: number } | undefined;
      try {
        for await (const ev of stream) {
          if (ev.type === "text") emit("text", { delta: ev.delta });
          else {
            content = ev.content;
            calls = ev.toolCalls.filter((c) => c.function.name);
            usage = ev.usage;
          }
        }
      } catch (err) {
        // Too long for the model: condense and try again (the window may be smaller than
        // thought).
        if (window && !refused && !signal?.aborted && !late?.aborted && isContextError(err)) {
          window = Math.min(window, windowFromError(err) ?? window);
          full = refused = true;
          late = undefined;
          continue;
        }
        throw err;
      }
      late = undefined;
      refused = false;
      if (window && usage) {
        const estimate = estimateTokens(body.messages, tools);
        scale = Math.min(4, Math.max(0.5, usage.prompt / Math.max(1, estimate)));
        emit("usage", { used: usage.prompt + usage.completion, max: window });
      }
      // Some models end a turn without a word (e.g. after tool results), or only call tools
      // when they mustn't: ask again for the answer.
      const silent = !content.trim() && (final || !calls.length);
      if (silent && nudges < MAX_NUDGES) {
        nudges++;
        continue;
      }
      if (silent) {
        content = NO_ANSWER;
        emit("text", { delta: content });
      }
      if (!calls.length || final) {
        push({ role: "assistant", content });
        break;
      }
      push({ role: "assistant", content: content || null, tool_calls: calls });
      // A question waits for the user: its result is their answer, added by the app.
      let question: ({ id: string } & Question) | null = null;
      const argsOf = (call: ToolCall): unknown => {
        try {
          return JSON.parse(call.function.arguments || "{}");
        } catch {
          return call.function.arguments;
        }
      };
      // Calls that only read run side by side; changes run one after another, in order.
      const running = calls.every((c) => readsOnly(c.function.name))
        ? calls.map((call) => {
          emit("tool", { id: call.id, name: call.function.name, args: argsOf(call) });
          return runTool(call.function.name, call.function.arguments, ctx, allowed);
        })
        : null;
      for (const [i, call] of calls.entries()) {
        if (call.function.name === "ask_user" && question) {
          push({
            role: "tool",
            tool_call_id: call.id,
            content: JSON.stringify({ error: "Ask one question at a time" }),
          });
          continue;
        }
        const args = argsOf(call);
        // A question shows up as the question itself (not as a tool call), once it's valid.
        const ask = call.function.name === "ask_user";
        if (!ask && !running) emit("tool", { id: call.id, name: call.function.name, args });
        const res = await (running?.[i] ??
          runTool(call.function.name, call.function.arguments, ctx, allowed));
        if (res.question) {
          question = { id: call.id, ...res.question };
          continue;
        }
        if (ask) emit("tool", { id: call.id, name: call.function.name, args });
        emit("tool_result", {
          id: call.id,
          name: call.function.name,
          ok: res.ok,
          summary: res.summary,
        });
        if (res.change) emit("change", { id: call.id, ...res.change });
        const text = JSON.stringify(res.result);
        const content = text.length > MAX_TOOL_RESULT
          ? text.slice(0, MAX_TOOL_RESULT) + "…(truncated)"
          : text;
        push({ role: "tool", tool_call_id: call.id, content });
      }
      flush();
      if (question) {
        emit("question", question);
        emit("done", {});
        return;
      }
    }
    flush();
    emit("done", {});
  } catch (err) {
    if (signal?.aborted) return;
    const message = late?.aborted
      ? TOO_SLOW
      : err instanceof HttpError
      ? err.message
      : "The assistant failed";
    if (!(err instanceof HttpError) && !late?.aborted) console.error(err);
    // Only a model call fails (tools report their errors to the model), so the steps so far are
    // whole: the app keeps them and tries the failed step again with a new request.
    flush();
    emit("continue", { retry: true, message });
  }
}

/** A Response that streams the events of `run` as server-sent events; `signal` tells `run`
 *  that the client went away. */
export function sseResponse(
  run: (emit: Emit, signal: AbortSignal) => Promise<void>,
  headers: Record<string, string>,
): Response {
  const encoder = new TextEncoder();
  const gone = new AbortController();
  const body = new ReadableStream<Uint8Array>({
    cancel() {
      gone.abort();
    },
    async start(controller) {
      const emit: Emit = (event, data) => {
        try {
          controller.enqueue(encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
        } catch {
          // the client went away
        }
      };
      // A comment line every 15 s keeps proxies from closing a quiet connection.
      const ping = setInterval(() => emit("ping", {}), 15000);
      try {
        await run(emit, gone.signal);
      } finally {
        clearInterval(ping);
        try {
          controller.close();
        } catch {
          // already closed
        }
      }
    },
  });
  return new Response(body, {
    headers: {
      ...headers,
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache, no-store",
      "x-accel-buffering": "no",
    },
  });
}
