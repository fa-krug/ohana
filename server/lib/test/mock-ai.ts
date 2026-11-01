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
//   "letter" / "elternbrief" (also in an attached file) -> suggest_items from "Elternbrief": an
//                                            event in 7 days 15:00–17:00 at the school, and with
//                                            the user's Reminders (edit_reminders offered) a
//                                            task due in 5 days and a deadline in 3 days at 12:00
//   "find a <speciality> before <day>"    -> create_appointment_search
//   "appointment searches"                -> list_appointment_searches
//   "book <resultId> of <search>"         -> book_appointment_slot
//   "events"                              -> list_events for this month
// Asked for recipes (the meals generator's prompt) it answers with that many recipes as JSON in
// a Markdown block; POST /images/generations answers with a small PNG (b64_json).
// Asked to import a web page's recipe (the import prompt), it answers with one recipe titled
// like the page (tomatoes and the family's tags the page names) when the page mentions
// ingredients / Zutaten / recipe / Rezept, else with [].
// Asked to read a letter (the letter prompt, POST /ai/letter), it answers with JSON in a Markdown
// block: source "Elternbrief" (the letter's first line), an event in 7 days 15:00–17:00 in the
// schoolyard for the family's first member, a task due in 5 days and a deadline in 3 days at
// 12:00 (German titles when asked to answer in German). A letter saying "nothing" gets no items;
// one saying "sloppy" gets wrong items too (no date, end without start, unknown kind …).
// Asked to sort transactions into categories (the categorize prompt), it picks the category
// whose id or name occurs in a row's payee or description, searching the web once for a payee
// it can't place.
// After a tool result it says what happened; anything else is echoed. A message with images
// (content parts) gets "I see 2 images." before the echo.
// Asked to condense a conversation, it says how often it looked so far ("Looked 12 times.").
// It reports the tokens used (a token is 4 characters) when asked to (stream_options). The model
// "mock-large" has a context window of 64,000 tokens (in the model list), "mock-tiny" one of
// 12,000 that only its errors tell. Under .../v1/strict it refuses options it doesn't know
// (stream_options), like Mistral.

type Part = { type: string; text?: string };
type Msg = {
  role: string;
  content: string | null | Part[];
  tool_calls?: { id: string; function: { name: string } }[];
  tool_call_id?: string;
};

/** A message's text: the string, or its text parts joined. */
function textOf(content: Msg["content"]) {
  if (!Array.isArray(content)) return String(content ?? "");
  return content.filter((p) => p.type === "text").map((p) => p.text ?? "").join("\n");
}

function chunk(delta: Record<string, unknown>, finish: string | null = null) {
  return `data: ${JSON.stringify({ choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
}

type Call = { name: string; args: unknown };

/** An answer with its text and tool calls (one, or several in one step). */
function reply(stream: boolean, content: string, call?: Call | Call[]) {
  const calls = (Array.isArray(call) ? call : call ? [call] : []).map((c) => ({
    id: `call_${crypto.randomUUID().slice(0, 8)}`,
    type: "function",
    function: { name: c.name, arguments: JSON.stringify(c.args) },
  }));
  if (!stream) {
    return Response.json({
      choices: [{
        index: 0,
        message: { role: "assistant", content, ...(calls.length ? { tool_calls: calls } : {}) },
        finish_reason: calls.length ? "tool_calls" : "stop",
      }],
    });
  }
  let body = "";
  for (const word of content.match(/\S+\s*/g) ?? []) body += chunk({ content: word });
  for (const [index, toolCall] of calls.entries()) {
    // Arguments arrive in pieces, like real servers send them.
    const args = toolCall.function.arguments;
    body += chunk({
      tool_calls: [{
        index,
        id: toolCall.id,
        type: "function",
        function: { name: toolCall.function.name, arguments: "" },
      }],
    });
    for (let i = 0; i < args.length; i += 12) {
      body += chunk({ tool_calls: [{ index, function: { arguments: args.slice(i, i + 12) } }] });
    }
  }
  body += chunk({}, calls.length ? "tool_calls" : "stop") + "data: [DONE]\n\n";
  return new Response(body, { headers: { "content-type": "text/event-stream" } });
}

/** The categorize prompt: a category whose id or name occurs in a row's payee or description,
 *  else in what a web search for its payee found; unknown payees are searched once. */
function categorize(stream: boolean, system: string, messages: Msg[], canSearch: boolean) {
  const categories = [...system.matchAll(/^- ([a-z0-9-]+): (?:[^\w\s]\S* )?([^(\n]+?) \(/gmu)];
  const match = (text: string) =>
    categories.find(([, id, name]) => text.includes(id) || text.includes(name.toLowerCase()))
      ?.[1] ?? null;
  const found = new Map<string, string>();
  for (const m of messages.filter((m) => m.role === "tool")) {
    const result = JSON.parse(textOf(m.content));
    found.set(result.query, JSON.stringify(result.results ?? []).toLowerCase());
  }
  const answer: Record<string, string | null> = {};
  const unknown: string[] = [];
  for (const line of textOf(messages[1].content).split("\n")) {
    const [n, , , payee = "", description = ""] = line.split(" | ");
    answer[n] = match(`${payee} ${description}`.toLowerCase()) ??
      match(found.get(payee) ?? "");
    if (!answer[n] && payee && !found.has(payee)) unknown.push(payee);
  }
  if (canSearch && unknown.length && !found.size) {
    return reply(stream, "", { name: "web_search", args: { query: unknown[0] } });
  }
  return reply(stream, "```json\n" + JSON.stringify(answer) + "\n```");
}

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

const TINY_WINDOW = 12_000;

/** A 16×16 orange PNG: the mock's "photo". */
export const MOCK_PNG =
  "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAACXBIWXMAAAPoAAAD6AG1e1JrAAAAGUlEQVR4nGO4U6FBEmIY1VAxGkp3hmvSAAC5KnwQ90HjsgAAAABJRU5ErkJggg==";

/** The recipe generator's prompt: `count` recipes as JSON in a Markdown block (the first
 *  required tag, if any, on each). */
function recipes(stream: boolean, prompt: string) {
  const count = Number(/Generate exactly (\d+) recipes/.exec(prompt)?.[1] ?? 1);
  const required = /REQUIRED TAGS[^\n]*\n([^\n]+)/.exec(prompt)?.[1]?.split(",")[0]?.trim();
  const wish = /ADDITIONAL REQUIREMENTS:\n([^\n]+)/.exec(prompt)?.[1]?.trim();
  const de = /in German\)/.test(prompt);
  const list = Array.from({ length: count }, (_, i) => ({
    title: `${de ? "Mock-Rezept" : "Mock Recipe"} ${i + 1}${wish ? ` (${wish})` : ""}`,
    default_servings: 2,
    prep_time_minutes: 10,
    cook_time_minutes: 20 + i,
    leftover_days: 1,
    ingredients: [
      { name_en: "Tomato", name_de: "Tomate", category: "PRODUCE", quantity: 200 + i, unit_abbreviation: "g", order: 0 },
      { name_en: "Mock Herb", name_de: "Mockkraut", category: "PRODUCE", quantity: "1", unit_abbreviation: "Stk", order: 1 },
      { name_en: "Bad", quantity: -1, unit_abbreviation: "g" },
    ],
    manual_steps: [{ step_number: 1, instruction: "Chop everything." }, { step_number: 2, instruction: "Cook it." }],
    machine_steps: [],
    tag_names_en: required ? [required] : [],
  }));
  return reply(stream, "Here you go:\n```json\n" + JSON.stringify(list, null, 1) + "\n```");
}

/** The import prompt: one recipe from the page's title, or [] for a page without a recipe. */
function importRecipe(stream: boolean, prompt: string) {
  const end = prompt.lastIndexOf("\n\nConvert the recipe of this page");
  // The page's URL is left out (a page called /recipe/… without one is still no recipe).
  const page = prompt.slice(prompt.indexOf("WEB PAGE:"), end < 0 ? undefined : end).replace(/^URL: .*$/m, "");
  if (!/ingredients|zutaten|recipe|rezept/i.test(page)) return reply(stream, "[]");
  const de = /in German\)/.test(prompt);
  const title = /^Title: (.+)$/m.exec(page)?.[1]?.trim() || (de ? "Importiertes Rezept" : "Imported Recipe");
  const tags = (/ALL AVAILABLE TAGS:\n([^\n]+)/.exec(prompt)?.[1] ?? "")
    .split(/,\s*/)
    .map((t) => t.replace(/\s*\([^)]*\)$/, "").trim())
    .filter((t) => t && page.toLowerCase().includes(t.toLowerCase()));
  const recipe = {
    title,
    description: de ? "Von einer Webseite." : "From a web page.",
    default_servings: 4,
    prep_time_minutes: 15,
    cook_time_minutes: 30,
    leftover_days: 1,
    ingredients: [
      { name_en: "Tomato", name_de: "Tomate", category: "PRODUCE", quantity: 400, unit_abbreviation: "g", order: 0 },
      { name_en: "Onion", name_de: "Zwiebel", category: "PRODUCE", quantity: 1, unit_abbreviation: "pc", order: 1 },
    ],
    manual_steps: [{ step_number: 1, instruction: de ? "Alles kochen." : "Cook everything." }],
    machine_steps: [],
    tag_names_en: tags,
  };
  return reply(stream, "```json\n" + JSON.stringify([recipe]) + "\n```");
}

/** The letter prompt: a few items relative to the prompt's today (see the top). */
function letter(stream: boolean, system: string, text: string) {
  const today = /^Today is \w+, (\d{4}-\d{2}-\d{2})\./m.exec(system)?.[1] ?? new Date().toISOString().slice(0, 10);
  const de = /^Answer in German/m.test(system);
  const first = /^The family's members[^:]*: ([^,(.]+)/m.exec(system)?.[1]?.trim();
  const day = (n: number) => {
    const d = new Date(today + "T00:00:00Z");
    d.setUTCDate(d.getUTCDate() + n);
    return d.toISOString().slice(0, 10);
  };
  const source = text.trim().split("\n")[0].slice(0, 80) || "Elternbrief";
  if (/\bnothing\b/i.test(text)) return reply(stream, JSON.stringify({ source, items: [] }));
  const items: unknown[] = [
    {
      kind: "event",
      title: de ? "Schulfest" : "School party",
      date: day(7),
      start: "15:00",
      end: "17:00",
      location: de ? "Schulhof" : "Schoolyard",
      ...(first ? { person: first } : {}),
    },
    { kind: "task", title: de ? "Kuchen mitbringen" : "Bring a cake", date: day(5) },
    {
      kind: "deadline",
      title: de ? "Einverständniserklärung abgeben" : "Return the consent form",
      date: day(3),
      start: "12:00",
      note: de ? "Von einem Elternteil unterschrieben" : "Signed by a parent",
    },
  ];
  if (/\bsloppy\b/i.test(text)) {
    items.push(
      { kind: "deadline", title: "Reply" },
      { kind: "event", title: "Concert", date: day(9), end: "20:00" },
      { kind: "event", title: "Trip", date: "2026-02-30" },
      { kind: "todo", title: "Something" },
      { kind: "task", title: "x".repeat(300) },
      "not an item",
    );
  }
  return reply(stream, "Here is what I found:\n```json\n" + JSON.stringify({ source, items }, null, 1) + "\n```");
}

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

  if (last.role === "tool") {
    const result = JSON.parse(textOf(last.content) || "{}");
    if (result.error) return reply(stream, `That didn't work: ${result.error}`);
    const called = messages.flatMap((m) => m.tool_calls ?? []).find((c) => c.id === last.tool_call_id);
    const device = called?.function.name === "edit_apple_calendar"
      ? { changes: "calendar", left: "calendars" }
      : { changes: "reminder", left: "Reminders" };
    const suggested = called?.function.name === "suggest_items";
    const text = result.skipped
      ? "You skipped my question."
      : suggested && result.applied === true
      ? `Added ${result.results?.filter((r: { ok?: boolean }) => r.ok).length ?? 0} of ${result.results?.length ?? 0} suggestions.`
      : suggested && result.applied === false
      ? "OK, I added nothing."
      : result.applied === true
      ? `Done: ${result.results?.filter((r: { ok?: boolean }) => r.ok).length ?? 0} of ${
        result.results?.length ?? 0
      } ${device.changes} changes applied.`
      : result.applied === false
      ? `OK, I left your ${device.left} as they were.`
      : Array.isArray(result.calendars) && Array.isArray(result.events)
      ? `You have ${result.events.length} events in ${result.calendars.length} calendars.`
      : Array.isArray(result.days) && result.days.every((d: { items?: unknown }) => Array.isArray(d.items))
      ? `${result.days.reduce((n: number, d: { items: unknown[] }) => n + d.items.length, 0)} items to buy on ${result.days.length} shopping days.`
      : Array.isArray(result.lists) && Array.isArray(result.items)
      ? `You have ${result.items.length} open reminders in ${result.lists.length} lists.`
      : result.selected || result.ownAnswer
      ? `You answered: ${
        [...(result.selected ?? []), result.ownAnswer].filter(Boolean).join(", ")
      }.`
      : result.changed !== undefined
      ? `Done: ${result.changed} days changed.`
      : result.results?.[0]?.expression !== undefined
      ? // eslint-disable-next-line @typescript-eslint/no-explicit-any
        result.results.map((r: any) => `${r.expression} = ${r.value ?? r.error}`).join("; ")
      : result.groups
      ? `${result.groupCount} groups, ${result.total.expenseCents / 100} spent.`
      : result.results
      ? `I found ${result.results.length} results, e.g. ${result.results[0]?.title ?? "nothing"}.`
      : result.ok === true && result.title
      ? `Done: “${result.title}”.`
      : result.ok === true && result.iterationId
      ? `Planned ${result.meals.length} meals from ${result.from}.`
      : result.ok === true && result.name
      ? `Search “${result.name}” is set up.`
      : result.ok === true
      ? "Done."
      : result.title !== undefined
      ? `The page is called “${result.title}”.`
      : result.incomeCents !== undefined
      ? `Income ${result.incomeCents / 100}, expenses ${result.expenseCents / 100}.`
      : `Here is what I found: ${JSON.stringify(result).slice(0, 200)}`;
    return reply(stream, text);
  }

  const text = textOf(last.content);
  const images = Array.isArray(last.content)
    ? last.content.filter((p) => p.type === "image_url").length
    : 0;
  const lower = text.toLowerCase();
  const today = /Today is (\d{4}-\d{2}-\d{2})/.exec(system)?.[1] ??
    new Date().toISOString().slice(0, 10);
  const dates = text.match(/\d{4}-\d{2}-\d{2}/g) ?? [];
  const url = /https?:\/\/\S+/.exec(text)?.[0];

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
