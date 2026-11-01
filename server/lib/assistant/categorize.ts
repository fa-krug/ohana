// Sorts transactions into the family's categories. First without AI: a row gets the category
// that earlier transactions of the same payee mostly have. The rest goes to the family's AI
// model in batches, with the categories and how the family sorted payees before; it may look up
// payees it doesn't know on the web (when search is set up). Its answer is a JSON object of row
// number -> category id. Only categories that fit (income / expense) count.

import { HttpError } from "@/lib/api/http";
import type { Lang } from "@/lib/i18n/config";
import { categoryTree } from "@/lib/finance/category-tree";
import { similarKey } from "@/lib/finance/finance";
import type { CategoryRow, TransactionRow } from "@/lib/finance/store";
import type { NetOptions } from "./net";
import { type ChatMessage, type Provider, streamChat } from "./provider";
import type { SearchProvider } from "./store";
import { runTool, type ToolContext, toolsFor } from "./tools";

/** Rows per model request, and requests at once. */
const BATCH = 50;
const PARALLEL = 4;
/** Already sorted payees shown as examples. */
const MAX_EXAMPLES = 60;
/** Web searches per batch, and how long searching may go on (the request waits for it). */
const MAX_SEARCHES = 6;
const SEARCH_BUDGET_MS = 60_000;
const MAX_SEARCH_RESULT = 6_000;
/** The share of a payee's earlier transactions one category needs to be used without AI. */
const MAJORITY = 0.6;

export const MARKER = "You sort bank transactions into categories.";

const LANGUAGES: Record<Lang, string> = { en: "English", de: "German" };

/** Whether a category may hold a transaction of this amount. */
export function fits(c: CategoryRow, amountCents: number): boolean {
  if (c.kind === "both" || amountCents === 0) return true;
  return (c.kind === "income") === amountCents > 0;
}

/**
 * Categories from similar transactions that already have one: the category most of them have
 * (at least 60 %), if it fits the amount. No AI involved.
 */
export function matchSimilar(
  rows: TransactionRow[],
  sorted: TransactionRow[],
  categories: CategoryRow[],
): Map<string, string> {
  const byId = new Map(categories.map((c) => [c.id, c]));
  const counts = new Map<string, Map<string, number>>();
  for (const t of sorted) {
    const key = similarKey(t);
    if (!key || !t.category_id || !byId.has(t.category_id)) continue;
    const c = counts.get(key) ?? new Map<string, number>();
    c.set(t.category_id, (c.get(t.category_id) ?? 0) + 1);
    counts.set(key, c);
  }
  const out = new Map<string, string>();
  for (const row of rows) {
    const c = counts.get(similarKey(row));
    if (!c) continue;
    const fitting = [...c].filter(([id]) => fits(byId.get(id)!, row.amount_cents));
    const total = fitting.reduce((sum, [, n]) => sum + n, 0);
    const [best, n] = fitting.sort((a, b) => b[1] - a[1])[0] ?? [];
    if (best && n / total >= MAJORITY) out.set(row.id, best);
  }
  return out;
}

function oneLine(s: string, max: number) {
  return s.replace(/[\s|]+/g, " ").trim().slice(0, max);
}

function rowLine(n: number, t: TransactionRow) {
  return `${n} | ${t.day} | ${(t.amount_cents / 100).toFixed(2)} | ${oneLine(t.payee, 80)} | ${
    oneLine(t.description, 160)
  }`;
}

/** The newest category per payee, from rows that have one: how this family sorts. */
function examples(sorted: TransactionRow[], categories: CategoryRow[]): string[] {
  const ids = new Set(categories.map((c) => c.id));
  const seen = new Set<string>();
  const out: string[] = [];
  for (const t of sorted) {
    const payee = oneLine(t.payee || t.description, 80);
    const key = payee.toLowerCase();
    if (!t.category_id || !ids.has(t.category_id) || !payee || seen.has(key)) continue;
    seen.add(key);
    out.push(`${payee} -> ${t.category_id}`);
    if (out.length >= MAX_EXAMPLES) break;
  }
  return out;
}

export function categorizePrompt(
  categories: CategoryRow[],
  sorted: TransactionRow[],
  lang: Lang,
  search = false,
): string {
  const ex = examples(sorted, categories);
  const tree = categoryTree(categories);
  return [
    MARKER,
    `The statements are probably ${LANGUAGES[lang]}. Each row is: number | date | amount ` +
    "(negative = money going out) | payee | description.",
    'Categories (id: name after its parent categories, as in "Food > Groceries"; for which ' +
    "amounts):",
    ...tree.ordered.map((c) =>
      `- ${c.id}: ${c.icon ? c.icon + " " : ""}${tree.path(c.id)} (${
        c.kind === "both" ? "income and expenses" : c.kind === "income" ? "income" : "expenses"
      })`
    ),
    ...(ex.length ? ["How the family sorted earlier transactions (payee -> id):", ...ex] : []),
    ...(search
      ? [
        "If you don't know what a payee is (a company, shop or service), look it up with " +
        `web_search first. Search only for those, at most ${MAX_SEARCHES} searches.`,
      ]
      : []),
    'Answer with one JSON object and nothing else: {"<row number>": "<category id>"}. Use only ' +
    "the ids above, only categories that fit the amount, and null when you aren't fairly sure.",
  ].join("\n");
}

/** The JSON object in a model's answer (which may wrap it in a code fence or prose). */
export function parseAnswer(content: string): Record<string, unknown> {
  const start = content.indexOf("{");
  const end = content.lastIndexOf("}");
  if (start < 0 || end < start) return {};
  try {
    const data = JSON.parse(content.slice(start, end + 1));
    return data && typeof data === "object" && !Array.isArray(data) ? data : {};
  } catch {
    return {};
  }
}

export type Search = { provider: Exclude<SearchProvider, "none">; key: string };

interface AskOptions {
  provider: Provider;
  net: NetOptions;
  system: string;
  /** Web search for the model; null without. */
  search: Search | null;
  /** The family's stores, for the web search tool's context. */
  tools: Pick<ToolContext, "calendar" | "finance" | "db" | "familyId">;
  lang: Lang;
  deadline: number;
  signal?: AbortSignal;
}

/** One batch: the model may search the web a few times, then answers with the JSON object. */
async function ask(o: AskOptions, rows: TransactionRow[]): Promise<Record<string, unknown>> {
  const messages: ChatMessage[] = [
    { role: "system", content: o.system },
    { role: "user", content: rows.map((t, i) => rowLine(i + 1, t)).join("\n") },
  ];
  const tools = o.search
    ? toolsFor({ writes: false, search: true }).filter((t) => t.function.name === "web_search")
    : undefined;
  const allowed = new Set(["web_search"]);
  let searches = 0;
  for (;;) {
    // Once the searches or the time are used up, the model has to answer.
    const canSearch = !!tools && searches < MAX_SEARCHES && Date.now() < o.deadline;
    let done: { content: string; toolCalls: ChatMessage["tool_calls"] } | null = null;
    for await (
      const ev of streamChat(
        o.provider,
        { messages, tools, toolChoice: canSearch ? "auto" : "none", temperature: 0 },
        o.net,
        o.signal,
      )
    ) {
      if (ev.type === "done") done = ev;
    }
    const calls = (done?.toolCalls ?? []).slice(0, MAX_SEARCHES - searches);
    if (!canSearch || !calls.length) return parseAnswer(done?.content ?? "");
    messages.push({ role: "assistant", content: done?.content || null, tool_calls: calls });
    for (const call of calls) {
      searches++;
      const res = await runTool(call.function.name, call.function.arguments, {
        ...o.tools,
        lang: o.lang,
        net: o.net,
        search: o.search,
        signal: o.signal,
      }, allowed);
      messages.push({
        role: "tool",
        tool_call_id: call.id,
        content: JSON.stringify(res.result).slice(0, MAX_SEARCH_RESULT),
      });
    }
  }
}

/**
 * The category the model picked for each row (rows it left open are missing). `sorted` are the
 * family's transactions that already have a category, newest first, as examples.
 */
export async function suggestCategories(opts: {
  provider: Provider;
  net: NetOptions;
  categories: CategoryRow[];
  rows: TransactionRow[];
  sorted: TransactionRow[];
  lang: Lang;
  search: Search | null;
  tools: Pick<ToolContext, "calendar" | "finance" | "db" | "familyId">;
  signal?: AbortSignal;
}): Promise<Map<string, string>> {
  const { provider, categories, rows } = opts;
  if (!provider.model) throw new HttpError(400, "Pick a model first");
  if (!categories.length) throw new HttpError(400, "There are no categories yet");
  const askOptions: AskOptions = {
    ...opts,
    system: categorizePrompt(categories, opts.sorted, opts.lang, !!opts.search),
    deadline: Date.now() + SEARCH_BUDGET_MS,
  };
  const byId = new Map(categories.map((c) => [c.id, c]));
  const byName = new Map(categories.map((c) => [c.name.toLowerCase(), c]));
  const batches: TransactionRow[][] = [];
  for (let i = 0; i < rows.length; i += BATCH) batches.push(rows.slice(i, i + BATCH));

  const out = new Map<string, string>();
  for (let i = 0; i < batches.length; i += PARALLEL) {
    const answers = await Promise.all(
      batches.slice(i, i + PARALLEL).map((batch) => ask(askOptions, batch)),
    );
    answers.forEach((answer, j) => {
      const batch = batches[i + j];
      for (const [key, value] of Object.entries(answer)) {
        const row = batch[Number(key) - 1];
        const ref = typeof value === "string" ? value.trim() : "";
        const category = byId.get(ref) ?? byName.get(ref.toLowerCase());
        if (row && category && fits(category, row.amount_cents)) out.set(row.id, category.id);
      }
    });
  }
  return out;
}
