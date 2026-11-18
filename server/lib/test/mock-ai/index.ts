// A scripted stand-in for an OpenAI-compatible API (family-planner's dev/mock_ai.ts), so the
// assistant can be tested and tried without a key (scripts/mock-ai.ts serves it). It picks a tool from keywords in the last message and
// answers in OpenAI's streaming format:
//   "vacation 2026-08-03 to 2026-08-07"  -> change_entries (the first "covers" type)
//   "calendar"                            -> get_calendar for this month
//   "spend" / "finance"                   -> finance_summary for this year
//   "add category <name>"                 -> manage_categories (add)
//   "delete category <name>"              -> manage_categories (delete)
//   "search <words>"                      -> web_search
//   "calculate <expression>"              -> calculate
//   "analyze <dimension>"                 -> analyze_transactions grouped by it, this year
//   a URL                                 -> fetch_page
//   "ask" / "ask several"                 -> ask_user: where to go (pick one / several)
//   "keep looking" / "keep looking N times" -> get_calendar 30 (N) times, then "Done looking."
//                                            (the looks before a summary count too)
//   "say nothing"                         -> get_calendar, then no words until tools are off
//   "stay silent"                         -> no words at all
//   "take your time"                      -> answers after 200 ms
//   "... slowly"                          -> every answer takes a second (e.g. "keep looking
//                                            slowly": half a minute of steps)
//   "keep looking, then fail"             -> get_calendar, then fails (503)
//   "calendar, then fail 2 times"         -> get_calendar, fails twice (503), then answers
//   "recipes" / "rezepte"                 -> list_recipes ("... with <tag>": tags)
//   "add recipe <title>"                  -> save_recipe (tomatoes, one step)
//   "meal plan" / "essensplan"            -> get_meal_plan
//   "set up a meal plan"                  -> plan_meals setup (1 week, shopping on Saturday)
//   "plan next week [without <tag>]"      -> plan_meals next (excludeTags)
//   "shopping list" / "einkaufsliste"     -> get_shopping_items
//   "reminders" / "erinnerungen"          -> get_reminders
//   "buy <name>"                          -> edit_reminders: add <name> to the shopping list
//   "remind me to <x> [in <list>]"        -> edit_reminders: add <x> (default list "shopping")
//   "complete <id>"                       -> edit_reminders: complete the reminder <id>
//   "ask and remind me to <x>"            -> edit_reminders and ask_user in one step (one waits)
//   "my calendars"                        -> get_apple_calendar
//   "schedule <title> at <start> [in <calendar>]" -> edit_apple_calendar: add it (start
//                                            "YYYY-MM-DD[THH:MM]", default calendar "Family")
//   "cancel event <id>"                   -> edit_apple_calendar: delete it (span "future")
//   "note <path>: <text>"                 -> edit_knowledge_notes: create the note <path>
//   "append to <ref>: <text>"             -> edit_knowledge_notes: append <text> to the note
//                                            (<ref>: a path when it has a ".", else a documentId)
//   "look at <documentId> [pages <a,b-c>]" -> view_knowledge_pages; then, given the pages,
//                                            "Saw <n> pages: <the pages' header>", else why not
//   "letter" / "elternbrief" (also in an attached file) -> suggest_items from "Elternbrief": an
//                                            event in 7 days 15:00–17:00 at the school, and with
//                                            the user's Reminders (edit_reminders offered) a
//                                            task due in 5 days and a deadline in 3 days at 12:00
//   "find a <speciality> before <day>"    -> create_appointment_search
//   "appointment searches"                -> list_appointment_searches
//   "book <resultId> of <search>"         -> book_appointment_slot
//   "events"                              -> list_events for this month
//   "knowledge <words>"                   -> search_knowledge; then cites the first hit
//                                            ("<name> says: … [[k:<id>]].", with "invent" also
//                                            a made-up [[k:999999]])
//   "read document <id> [page N] [part M]" -> read_knowledge; then "Read <name>, page <page> of
//                                            <pages>: <n> passages [[<first ref>]]."
//   "cite k:<id>[, k:<id> …]"             -> answers "Said here [[k:<id>]]." per ref, no tool
//   "remember <module>: <text>"           -> edit_memories: add <text> to the memory of <module>
//   "forget <id>"                         -> edit_memories: remove the memory <id>
// The prompts of the other features (recipes, recipe import, letters, knowledge cards and page
// transcriptions, the health booklet scan, categorizing) are answered by their own files beside
// this one, each described there.
// After a tool result it says what happened; anything else is echoed. A message with images
// (content parts) gets "I see 2 images." before the echo.
// Asked to condense a conversation, it says how often it looked so far ("Looked 12 times.").
// It reports the tokens used (a token is 4 characters) when asked to (stream_options). The model
// "mock-large" has a context window of 64,000 tokens (in the model list), "mock-tiny" one of
// 16,000 that only its errors tell. Under .../v1/strict it refuses options it doesn't know
// (stream_options), like Mistral.

import { categorize } from "./finance";
import { healthScan } from "./health";
import { card, transcription } from "./knowledge";
import { letter } from "./letter";
import { importRecipe, MOCK_PNG, recipes } from "./meals";
import { type Msg, reply, textOf } from "./reply";
import { afterToolResult } from "./tool-results";

export { MOCK_PNG } from "./meals";
export { MOCK_TRANSCRIPTION } from "./knowledge";

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

const TINY_WINDOW = 16_000;

/** How often the conversation looked at the calendar: in the summary, and after it. */
function looks(messages: Msg[]) {
  const before = messages.map((m) => /Looked (\d+) times/.exec(textOf(m.content))?.[1])
    .findLast(Boolean);
  return Number(before ?? 0) + messages.filter((m) => m.role === "tool").length;
}

export async function mockAi(req: Request): Promise<Response> {
  const strict = /\/v1\/strict\//.test(new URL(req.url).pathname);
  const path = new URL(req.url).pathname.replace(/^.*\/v1(\/strict)?/, "");
  if (req.method === "GET" && path === "/models") {
    return Response.json({
      data: [{ id: "mock-large", context_length: 64_000 }, { id: "mock-small" }, {
        id: "mock-tiny",
      }],
    });
  }
  if (req.method === "POST" && path === "/images/generations") {
    const body = await req.json();
    if (!body.model || !body.prompt) return Response.json({ error: { message: "model and prompt are required" } }, { status: 400 });
    return Response.json({ created: 0, data: [{ b64_json: MOCK_PNG }] });
  }
  if (req.method !== "POST" || path !== "/chat/completions") {
    return Response.json({ error: { message: "Not found" } }, { status: 404 });
  }
  const body = await req.json();
  if (strict && body.stream_options) {
    return Response.json({
      object: "error",
      message: {
        detail: [{
          type: "extra_forbidden",
          loc: ["body", "stream_options"],
          msg: "Extra inputs are not permitted",
        }],
      },
    }, { status: 422 });
  }
  const tokens = Math.ceil(JSON.stringify([body.messages, body.tools ?? []]).length / 4);
  if (body.model === "mock-tiny" && tokens > TINY_WINDOW) {
    return Response.json({
      error: {
        message:
          `This model's maximum context length is ${TINY_WINDOW} tokens. However, your messages resulted in ${tokens} tokens.`,
      },
    }, { status: 400 });
  }
  const res = await respond(req, body);
  if (!body.stream_options?.include_usage || !body.stream || !res.ok) return res;
  // The tokens come in a chunk of their own, before the end.
  const usage = `data: ${
    JSON.stringify({ choices: [], usage: { prompt_tokens: tokens, completion_tokens: 10 } })
  }\n\n`;
  const text = (await res.text()).replace("data: [DONE]", usage + "data: [DONE]");
  return new Response(text, { headers: { "content-type": "text/event-stream" } });
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function respond(req: Request, body: any): Promise<Response> {
  const messages: Msg[] = body.messages ?? [];
  const last = messages.at(-1)!;
  const stream = body.stream === true;
  const tools = new Set(
    (body.tools ?? []).map((t: { function: { name: string } }) => t.function.name),
  );

  const system = textOf(messages[0]?.content);
  if (system.startsWith("You condense a conversation")) {
    const input = textOf(last.content);
    const before = Number(/Looked (\d+) times/.exec(input)?.[1] ?? 0);
    const n = before + (input.match(/^Result of get_calendar/gm)?.length ?? 0);
    return reply(stream, `Looked ${n} times. Condensed: ${input.length} characters.`);
  }
  if (textOf(messages[0]?.content).startsWith("You are a professional recipe creator")) {
    return recipes(stream, textOf(messages[0]?.content));
  }
  if (system.startsWith("You are a professional recipe editor")) return importRecipe(stream, system);
  if (system.startsWith("You find the events, tasks and deadlines in a letter")) {
    return letter(stream, system, textOf(last.content));
  }
  if (system.startsWith("You write a card for a document")) return card(stream, system, textOf(last.content));
  if (system.startsWith("You transcribe one scanned page")) return transcription(stream, last);
  if (system.startsWith("You read photos of pages of a German vaccination booklet")) return healthScan(stream, system, last);
  if (system.startsWith("You sort bank transactions into categories.")) {
    return categorize(
      stream,
      system,
      messages,
      tools.has("web_search") && body.tool_choice !== "none",
    );
  }

  const asked = textOf(messages.findLast((m) => m.role === "user")?.content ?? "");
  if (/stay silent/i.test(asked)) return reply(stream, "");
  if (/say nothing/i.test(asked)) {
    if (body.tool_choice === "none") return reply(stream, "Here is the calendar.");
    if (last.role === "tool") return reply(stream, "");
    return reply(stream, "", {
      name: "get_calendar",
      args: { from: "2026-01-01", to: "2026-01-31" },
    });
  }
  if (/\bslowly\b/i.test(asked)) await wait(1000, req.signal);
  if (/take your time/i.test(asked)) {
    await wait(200, req.signal);
    return reply(stream, "Sorry for the wait.");
  }
  const fails = /then fail(?: (\d+) times)?/i.exec(asked);
  if (fails && last.role === "tool") {
    const n = (failed.get(asked) ?? 0) + 1;
    failed.set(asked, n);
    if (!fails[1] || n <= Number(fails[1])) {
      return Response.json({ error: { message: "Overloaded" } }, { status: 503 });
    }
  }
  const looking = /keep looking(?: (\d+) times)?/i.exec(asked);
  if (looking) {
    const n = looks(messages);
    if (n >= Number(looking[1] ?? 30) || body.tool_choice === "none") {
      return reply(stream, `Done looking: ${n} times.`);
    }
    return reply(stream, "", {
      name: "get_calendar",
      args: { from: "2026-01-01", to: "2026-01-31" },
    });
  }

  // The pages a device sent for view_knowledge_pages (a message of their own after the result).
  if (last.role === "user" && textOf(last.content).startsWith("[Pages for view_knowledge_pages")) {
    const n = Array.isArray(last.content) ? last.content.filter((p) => p.type === "image_url").length : 0;
    return reply(stream, `Saw ${n} pages: ${textOf(last.content).split("\n")[0]}`);
  }
  if (last.role === "tool") return afterToolResult(stream, messages, asked);

  const text = textOf(last.content);
  const images = Array.isArray(last.content)
    ? last.content.filter((p) => p.type === "image_url").length
    : 0;
  const lower = text.toLowerCase();
  const today = /Today is (\d{4}-\d{2}-\d{2})/.exec(system)?.[1] ??
    new Date().toISOString().slice(0, 10);
  const dates = text.match(/\d{4}-\d{2}-\d{2}/g) ?? [];
  const url = /https?:\/\/\S+/.exec(text)?.[0];

  const knowledge = /^knowledge (.+)$/i.exec(text);
  if (knowledge && tools.has("search_knowledge")) {
    return reply(stream, "", { name: "search_knowledge", args: { query: knowledge[1].replace(/\binvent\b/i, "").trim() } });
  }
  const read = /^read document (\S+)(?: page (\d+))?(?: part (\d+))?$/i.exec(text);
  if (read && tools.has("read_knowledge")) {
    return reply(stream, "", {
      name: "read_knowledge",
      args: { documentId: read[1], ...(read[2] ? { page: Number(read[2]) } : {}), ...(read[3] ? { part: Number(read[3]) } : {}) },
    });
  }
  const cite = /^cite (k:\d+(?:,\s*k:\d+)*)$/i.exec(text);
  if (cite) return reply(stream, cite[1].split(",").map((r) => `Said here [[${r.trim()}]].`).join(" "));
  const remember = /^remember (\w+): (.+)$/i.exec(text);
  if (remember && tools.has("edit_memories")) {
    return reply(stream, "", {
      name: "edit_memories",
      args: { ops: [{ action: "add", module: remember[1].toLowerCase(), text: remember[2] }] },
    });
  }
  const forget = /^forget (\S+)$/i.exec(text);
  if (forget && tools.has("edit_memories")) {
    return reply(stream, "", { name: "edit_memories", args: { ops: [{ action: "remove", id: forget[1] }] } });
  }
  if (/vacation|urlaub/.test(lower) && dates.length && tools.has("change_entries")) {
    const type = /- ([a-z0-9-]+): “[^”]*” \(covers\)/.exec(system)?.[1] ?? "vacation";
    return reply(stream, "I'll add that.", {
      name: "change_entries",
      args: {
        ops: [{
          action: "add",
          type,
          from: dates[0],
          to: dates[1] ?? dates[0],
          skipWeekends: true,
        }],
      },
    });
  }
  const recipe = /^add recipe (.+)$/i.exec(text);
  if (recipe && tools.has("save_recipe")) {
    return reply(stream, "", {
      name: "save_recipe",
      args: {
        title: recipe[1],
        servings: 2,
        ingredients: [{ name: "Tomato", quantity: 200, unit: "g" }],
        steps: ["Cook the tomatoes."],
      },
    });
  }
  if (/set up a meal plan/i.test(text) && tools.has("plan_meals")) {
    return reply(stream, "", { name: "plan_meals", args: { action: "setup", weeks: 1, shoppingDays: ["Saturday"] } });
  }
  const planNext = /plan next week(?: without (\S+))?/i.exec(text);
  if (planNext && tools.has("plan_meals")) {
    return reply(stream, "", {
      name: "plan_meals",
      args: { action: "next", ...(planNext[1] ? { excludeTags: [planNext[1]] } : {}) },
    });
  }
  if (/meal plan|essensplan/.test(lower)) return reply(stream, "", { name: "get_meal_plan", args: {} });
  const askAndRemind = /^ask and remind me to (.+)$/i.exec(text);
  if (askAndRemind && tools.has("edit_reminders")) {
    return reply(stream, "", [
      { name: "edit_reminders", args: { ops: [{ op: "add", list: "shopping", title: askAndRemind[1] }] } },
      { name: "ask_user", args: { question: "Anything else?", options: ["Yes", "No"] } },
    ]);
  }
  const buy = /^buy (.+)$/i.exec(text);
  const remind = /^remind me to (.+?)(?: (?:in|on) (\S+))?$/i.exec(text);
  if ((buy || remind) && tools.has("edit_reminders")) {
    return reply(stream, "", {
      name: "edit_reminders",
      args: { ops: [{ op: "add", list: remind?.[2] ?? "shopping", title: buy?.[1] ?? remind![1] }] },
    });
  }
  const complete = /^complete (\S+)$/i.exec(text);
  if (complete && tools.has("edit_reminders")) {
    return reply(stream, "", { name: "edit_reminders", args: { ops: [{ op: "complete", id: complete[1] }] } });
  }
  const schedule = /^schedule (.+?) at (\S+)(?: in (.+))?$/i.exec(text);
  if (schedule && tools.has("edit_apple_calendar")) {
    return reply(stream, "", {
      name: "edit_apple_calendar",
      args: { ops: [{ op: "add", calendar: schedule[3] ?? "Family", title: schedule[1], start: schedule[2] }] },
    });
  }
  const cancel = /^cancel event (\S+)$/i.exec(text);
  if (cancel && tools.has("edit_apple_calendar")) {
    return reply(stream, "", { name: "edit_apple_calendar", args: { ops: [{ op: "delete", id: cancel[1], span: "future" }] } });
  }
  const note = /^note (\S+): (.+)$/is.exec(text);
  if (note && tools.has("edit_knowledge_notes")) {
    return reply(stream, "", { name: "edit_knowledge_notes", args: { ops: [{ op: "create", path: note[1], content: note[2] }] } });
  }
  const look = /^look at (\S+)(?: pages (\S+))?$/i.exec(text);
  if (look && tools.has("view_knowledge_pages")) {
    return reply(stream, "", {
      name: "view_knowledge_pages",
      args: { documentId: look[1], ...(look[2] ? { pages: look[2].split(",") } : {}) },
    });
  }
  const append = /^append to (\S+): (.+)$/is.exec(text);
  if (append && tools.has("edit_knowledge_notes")) {
    const ref = append[1].includes(".") ? { path: append[1] } : { documentId: append[1] };
    return reply(stream, "", { name: "edit_knowledge_notes", args: { ops: [{ op: "update", ...ref, append: append[2] }] } });
  }
  if (/\bletter\b|elternbrief/.test(lower) && tools.has("suggest_items")) {
    const day = (n: number) => {
      const d = new Date(today + "T00:00:00Z");
      d.setUTCDate(d.getUTCDate() + n);
      return d.toISOString().slice(0, 10);
    };
    const items: Record<string, unknown>[] = [
      { kind: "event", title: "School party", date: day(7), start: "15:00", end: "17:00", location: "Schoolyard" },
    ];
    if (tools.has("edit_reminders")) {
      items.push(
        { kind: "task", title: "Bring a cake", date: day(5) },
        { kind: "deadline", title: "Return the consent form", date: day(3), start: "12:00", note: "Signed by a parent" },
      );
    }
    return reply(stream, "", { name: "suggest_items", args: { source: "Elternbrief", items } });
  }
  if (/my calendars/.test(lower) && tools.has("get_apple_calendar")) {
    return reply(stream, "", { name: "get_apple_calendar", args: {} });
  }
  if (/shopping list|einkaufsliste/.test(lower) && tools.has("get_shopping_items")) {
    return reply(stream, "", { name: "get_shopping_items", args: {} });
  }
  if (/reminders|erinnerungen/.test(lower) && tools.has("get_reminders")) {
    return reply(stream, "", { name: "get_reminders", args: {} });
  }
  const recipesWith = /^(?:recipes|rezepte)(?: with (.+))?$/i.exec(text);
  if (recipesWith) {
    return reply(stream, "", { name: "list_recipes", args: recipesWith[1] ? { tags: [recipesWith[1]] } : {} });
  }
  const find = /find an? (.+?) before (\d{4}-\d{2}-\d{2})/i.exec(text);
  if (find && tools.has("create_appointment_search")) {
    return reply(stream, "I'll set up a search.", {
      name: "create_appointment_search",
      args: { speciality: find[1], before: find[2] },
    });
  }
  const book = /^book (\d+) of (.+)$/i.exec(text);
  if (book && tools.has("book_appointment_slot")) {
    return reply(stream, "", {
      name: "book_appointment_slot",
      args: { search: book[2], resultId: Number(book[1]), person: "Mia" },
    });
  }
  if (/appointment searches|terminsuchen/.test(lower)) {
    return reply(stream, "", { name: "list_appointment_searches", args: {} });
  }
  if (/^events$/.test(lower)) {
    const month = today.slice(0, 7);
    return reply(stream, "", { name: "list_events", args: { from: `${month}-01`, to: `${month}-28` } });
  }
  if (/calendar|kalender/.test(lower)) {
    const month = today.slice(0, 7);
    return reply(stream, "", {
      name: "get_calendar",
      args: { from: `${month}-01`, to: `${month}-28` },
    });
  }
  const category = /^(add|delete) category (.+)$/i.exec(text);
  if (category && tools.has("manage_categories")) {
    const [, action, name] = category;
    return reply(stream, "", {
      name: "manage_categories",
      args: action.toLowerCase() === "add"
        ? { action: "add", name, icon: "🐾" }
        : { action: "delete", category: name },
    });
  }
  if (/spen[dt]|finance|ausgegeben|finanzen/.test(lower)) {
    const year = today.slice(0, 4);
    return reply(stream, "", {
      name: "finance_summary",
      args: { from: `${year}-01-01`, to: `${year}-12-31` },
    });
  }
  const calc = /^(?:calculate|berechne) (.+)$/i.exec(text);
  if (calc) return reply(stream, "", { name: "calculate", args: { expressions: [calc[1]] } });
  const analyze = /^(?:analyze|analysiere) (\w+)$/i.exec(text);
  if (analyze) {
    const year = today.slice(0, 4);
    return reply(stream, "", {
      name: "analyze_transactions",
      args: { from: `${year}-01-01`, to: `${year}-12-31`, groupBy: [analyze[1].toLowerCase()] },
    });
  }
  if (url) return reply(stream, "", { name: "fetch_page", args: { url } });
  if (/^(ask|frag)\b/.test(lower)) {
    return reply(stream, "Let me ask first.", {
      name: "ask_user",
      args: {
        question: "Where would you like to go?",
        options: ["Beach", "Mountains", "City"],
        multiple: /several|mehrere/.test(lower),
      },
    });
  }
  if (/^(search|suche)\b/.test(lower) && tools.has("web_search")) {
    return reply(stream, "", { name: "web_search", args: { query: text.replace(/^\S+\s*/, "") } });
  }
  const seen = images ? `I see ${images} image${images > 1 ? "s" : ""}. ` : "";
  return reply(stream, `${seen}Mock reply: ${text}`);
}
