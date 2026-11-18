// The mock AI's chat: what it does with the user's message (see the list at the top of
// index.ts). A turn first goes through the pacing steps (silence, waiting, failing, looking
// again and again), then the commands, the first that fits answering; else it echoes.

import { letterItems } from "./letter";
import { type Call, type Msg, reply, textOf } from "./reply";

/** What a command sees of the request. */
export type Turn = {
  req: Request;
  stream: boolean;
  messages: Msg[];
  last: Msg;
  system: string;
  /** The user's last message. */
  asked: string;
  /** The last message's text (for commands: the user's). */
  text: string;
  lower: string;
  tools: Set<string>;
  toolChoice: unknown;
  today: string;
  dates: string[];
};

type Step = (t: Turn) => Response | null | Promise<Response | null>;

/** Waits `ms`, or fails once the request is aborted. */
function wait(ms: number, signal: AbortSignal) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener("abort", () => {
      clearTimeout(timer);
      reject(signal.reason);
    });
  });
}

/** How often a "then fail N times" message failed so far. */
const failed = new Map<string, number>();

/** How often the conversation looked at the calendar: in the summary, and after it. */
function looks(messages: Msg[]) {
  const before = messages.map((m) => /Looked (\d+) times/.exec(textOf(m.content))?.[1])
    .findLast(Boolean);
  return Number(before ?? 0) + messages.filter((m) => m.role === "tool").length;
}

const JANUARY = { from: "2026-01-01", to: "2026-01-31" };

/** "say nothing": the calendar, then no words until the tools are off. */
function sayNothing(t: Turn) {
  if (t.toolChoice === "none") return reply(t.stream, "Here is the calendar.");
  if (t.last.role === "tool") return reply(t.stream, "");
  return reply(t.stream, "", { name: "get_calendar", args: JANUARY });
}

/** "then fail [N times]": after a tool result, 503 (N times, or always). */
function failing(t: Turn) {
  const fails = /then fail(?: (\d+) times)?/i.exec(t.asked);
  if (!fails || t.last.role !== "tool") return null;
  const n = (failed.get(t.asked) ?? 0) + 1;
  failed.set(t.asked, n);
  if (fails[1] && n > Number(fails[1])) return null;
  return Response.json({ error: { message: "Overloaded" } }, { status: 503 });
}

/** "keep looking [N times]": the calendar again and again (30 times, or N). */
function keepLooking(t: Turn) {
  const looking = /keep looking(?: (\d+) times)?/i.exec(t.asked);
  if (!looking) return null;
  const n = looks(t.messages);
  if (n >= Number(looking[1] ?? 30) || t.toolChoice === "none") {
    return reply(t.stream, `Done looking: ${n} times.`);
  }
  return reply(t.stream, "", { name: "get_calendar", args: JANUARY });
}

/** Before anything else: how the turn behaves over time. */
export const PACING: Step[] = [
  (t) => (/stay silent/i.test(t.asked) ? reply(t.stream, "") : null),
  (t) => (/say nothing/i.test(t.asked) ? sayNothing(t) : null),
  async (t) => {
    if (/\bslowly\b/i.test(t.asked)) await wait(1000, t.req.signal);
    return null;
  },
  async (t) => {
    if (!/take your time/i.test(t.asked)) return null;
    await wait(200, t.req.signal);
    return reply(t.stream, "Sorry for the wait.");
  },
  failing,
  keepLooking,
];

/** A command: the message matches `re` (and the tool is offered), then it calls a tool. */
type Phrase = {
  re: RegExp;
  /** The tool that has to be offered (default: `call`'s, when it returns one). */
  needs?: string;
  /** On the lower-cased text instead of the text. */
  lower?: boolean;
  call: (m: RegExpExecArray, t: Turn) => Call;
  /** Words before the call. */
  say?: string;
};

const thisMonth = (t: Turn) => {
  const month = t.today.slice(0, 7);
  return { from: `${month}-01`, to: `${month}-28` };
};
const thisYear = (t: Turn) => {
  const year = t.today.slice(0, 4);
  return { from: `${year}-01-01`, to: `${year}-12-31` };
};

const PHRASES: Phrase[] = [
  {
    re: /^knowledge (.+)$/i,
    call: (m) => ({ name: "search_knowledge", args: { query: m[1].replace(/\binvent\b/i, "").trim() } }),
  },
  {
    re: /^read document (\S+)(?: page (\d+))?(?: part (\d+))?$/i,
    call: (m) => ({
      name: "read_knowledge",
      args: { documentId: m[1], ...(m[2] ? { page: Number(m[2]) } : {}), ...(m[3] ? { part: Number(m[3]) } : {}) },
    }),
  },
  {
    re: /^remember (\w+): (.+)$/i,
    call: (m) => ({ name: "edit_memories", args: { ops: [{ action: "add", module: m[1].toLowerCase(), text: m[2] }] } }),
  },
  { re: /^forget (\S+)$/i, call: (m) => ({ name: "edit_memories", args: { ops: [{ action: "remove", id: m[1] }] } }) },
  {
    re: /^add recipe (.+)$/i,
    call: (m) => ({
      name: "save_recipe",
      args: { title: m[1], servings: 2, ingredients: [{ name: "Tomato", quantity: 200, unit: "g" }], steps: ["Cook the tomatoes."] },
    }),
  },
  {
    re: /set up a meal plan/i,
    call: () => ({ name: "plan_meals", args: { action: "setup", weeks: 1, shoppingDays: ["Saturday"] } }),
  },
  {
    re: /plan next week(?: without (\S+))?/i,
    call: (m) => ({ name: "plan_meals", args: { action: "next", ...(m[1] ? { excludeTags: [m[1]] } : {}) } }),
  },
  { re: /meal plan|essensplan/, lower: true, needs: "", call: () => ({ name: "get_meal_plan", args: {} }) },
  {
    re: /^complete (\S+)$/i,
    call: (m) => ({ name: "edit_reminders", args: { ops: [{ op: "complete", id: m[1] }] } }),
  },
  {
    re: /^schedule (.+?) at (\S+)(?: in (.+))?$/i,
    call: (m) => ({
      name: "edit_apple_calendar",
      args: { ops: [{ op: "add", calendar: m[3] ?? "Family", title: m[1], start: m[2] }] },
    }),
  },
  {
    re: /^cancel event (\S+)$/i,
    call: (m) => ({ name: "edit_apple_calendar", args: { ops: [{ op: "delete", id: m[1], span: "future" }] } }),
  },
  {
    re: /^note (\S+): (.+)$/is,
    call: (m) => ({ name: "edit_knowledge_notes", args: { ops: [{ op: "create", path: m[1], content: m[2] }] } }),
  },
  {
    re: /^look at (\S+)(?: pages (\S+))?$/i,
    call: (m) => ({ name: "view_knowledge_pages", args: { documentId: m[1], ...(m[2] ? { pages: m[2].split(",") } : {}) } }),
  },
  {
    re: /^append to (\S+): (.+)$/is,
    call: (m) => ({
      name: "edit_knowledge_notes",
      args: { ops: [{ op: "update", ...(m[1].includes(".") ? { path: m[1] } : { documentId: m[1] }), append: m[2] }] },
    }),
  },
  { re: /my calendars/, lower: true, call: () => ({ name: "get_apple_calendar", args: {} }) },
  { re: /shopping list|einkaufsliste/, lower: true, call: () => ({ name: "get_shopping_items", args: {} }) },
  { re: /reminders|erinnerungen/, lower: true, call: () => ({ name: "get_reminders", args: {} }) },
  {
    re: /^(?:recipes|rezepte)(?: with (.+))?$/i,
    needs: "",
    call: (m) => ({ name: "list_recipes", args: m[1] ? { tags: [m[1]] } : {} }),
  },
  {
    re: /find an? (.+?) before (\d{4}-\d{2}-\d{2})/i,
    say: "I'll set up a search.",
    call: (m) => ({ name: "create_appointment_search", args: { speciality: m[1], before: m[2] } }),
  },
  {
    re: /^book (\d+) of (.+)$/i,
    call: (m) => ({ name: "book_appointment_slot", args: { search: m[2], resultId: Number(m[1]), person: "Mia" } }),
  },
  {
    re: /appointment searches|terminsuchen/,
    lower: true,
    needs: "",
    call: () => ({ name: "list_appointment_searches", args: {} }),
  },
  { re: /^events$/, lower: true, needs: "", call: (_, t) => ({ name: "list_events", args: thisMonth(t) }) },
  { re: /calendar|kalender/, lower: true, needs: "", call: (_, t) => ({ name: "get_calendar", args: thisMonth(t) }) },
  {
    re: /^(add|delete) category (.+)$/i,
    call: (m) => ({
      name: "manage_categories",
      args: m[1].toLowerCase() === "add" ? { action: "add", name: m[2], icon: "🐾" } : { action: "delete", category: m[2] },
    }),
  },
  {
    re: /spen[dt]|finance|ausgegeben|finanzen/,
    lower: true,
    needs: "",
    call: (_, t) => ({ name: "finance_summary", args: thisYear(t) }),
  },
  { re: /^(?:calculate|berechne) (.+)$/i, needs: "", call: (m) => ({ name: "calculate", args: { expressions: [m[1]] } }) },
  {
    re: /^(?:analyze|analysiere) (\w+)$/i,
    needs: "",
    call: (m, t) => ({ name: "analyze_transactions", args: { ...thisYear(t), groupBy: [m[1].toLowerCase()] } }),
  },
  { re: /https?:\/\/\S+/, needs: "", call: (m) => ({ name: "fetch_page", args: { url: m[0] } }) },
  {
    re: /^(ask|frag)\b/,
    lower: true,
    needs: "",
    say: "Let me ask first.",
    call: (_, t) => ({
      name: "ask_user",
      args: { question: "Where would you like to go?", options: ["Beach", "Mountains", "City"], multiple: /several|mehrere/.test(t.lower) },
    }),
  },
  {
    re: /^(search|suche)\b/,
    lower: true,
    call: (_, t) => ({ name: "web_search", args: { query: t.text.replace(/^\S+\s*/, "") } }),
  },
];

/** The phrase as a command: its call when the message matches and the tool is offered. */
function phrase(p: Phrase): Step {
  return (t) => {
    const m = p.re.exec(p.lower ? t.lower : t.text);
    if (!m) return null;
    const call = p.call(m, t);
    const needs = p.needs ?? call.name;
    return needs && !t.tools.has(needs) ? null : reply(t.stream, p.say ?? "", call);
  };
}

/** "vacation 2026-08-03 to 2026-08-07": entries of the first "covers" type. */
function vacation(t: Turn) {
  if (!/vacation|urlaub/.test(t.lower) || !t.dates.length || !t.tools.has("change_entries")) return null;
  const type = /- ([a-z0-9-]+): “[^”]*” \(covers\)/.exec(t.system)?.[1] ?? "vacation";
  return reply(t.stream, "I'll add that.", {
    name: "change_entries",
    args: { ops: [{ action: "add", type, from: t.dates[0], to: t.dates[1] ?? t.dates[0], skipWeekends: true }] },
  });
}

/** "buy <x>" / "remind me to <x> [in <list>]" / "ask and remind me to <x>": Reminders. */
function reminders(t: Turn) {
  if (!t.tools.has("edit_reminders")) return null;
  const askAndRemind = /^ask and remind me to (.+)$/i.exec(t.text);
  if (askAndRemind) {
    return reply(t.stream, "", [
      { name: "edit_reminders", args: { ops: [{ op: "add", list: "shopping", title: askAndRemind[1] }] } },
      { name: "ask_user", args: { question: "Anything else?", options: ["Yes", "No"] } },
    ]);
  }
  const buy = /^buy (.+)$/i.exec(t.text);
  const remind = /^remind me to (.+?)(?: (?:in|on) (\S+))?$/i.exec(t.text);
  if (!buy && !remind) return null;
  return reply(t.stream, "", {
    name: "edit_reminders",
    args: { ops: [{ op: "add", list: remind?.[2] ?? "shopping", title: buy?.[1] ?? remind![1] }] },
  });
}

/** "letter" / "elternbrief": suggest_items (tasks and deadlines only with Reminders). */
function letterSuggestions(t: Turn) {
  if (!/\bletter\b|elternbrief/.test(t.lower) || !t.tools.has("suggest_items")) return null;
  const items = letterItems(t.today, false).slice(0, t.tools.has("edit_reminders") ? 3 : 1);
  return reply(t.stream, "", { name: "suggest_items", args: { source: "Elternbrief", items } });
}

/** "cite k:<id>[, …]": an answer citing them, no tool. */
function cite(t: Turn) {
  const refs = /^cite (k:\d+(?:,\s*k:\d+)*)$/i.exec(t.text);
  return refs ? reply(t.stream, refs[1].split(",").map((r) => `Said here [[${r.trim()}]].`).join(" ")) : null;
}

/** The commands in order: the first that answers wins (as the list at the top of index.ts). */
export const COMMANDS: Step[] = [
  ...PHRASES.slice(0, 2).map(phrase),
  cite,
  ...PHRASES.slice(2, 4).map(phrase),
  vacation,
  ...PHRASES.slice(4, 8).map(phrase),
  reminders,
  ...PHRASES.slice(8, 14).map(phrase),
  letterSuggestions,
  ...PHRASES.slice(14).map(phrase),
];

/** No command: the message echoed (with how many pictures it had). */
export function echo(t: Turn) {
  const images = Array.isArray(t.last.content) ? t.last.content.filter((p) => p.type === "image_url").length : 0;
  const seen = images ? `I see ${images} image${images > 1 ? "s" : ""}. ` : "";
  return reply(t.stream, `${seen}Mock reply: ${t.text}`);
}
