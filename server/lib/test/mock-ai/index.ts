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

import { COMMANDS, echo, PACING, type Turn } from "./commands";
import { categorize } from "./finance";
import { healthScan } from "./health";
import { card, transcription } from "./knowledge";
import { letter } from "./letter";
import { importRecipe, MOCK_PNG, recipes } from "./meals";
import { type Msg, reply, textOf } from "./reply";
import { afterToolResult } from "./tool-results";

export { MOCK_PNG } from "./meals";
export { MOCK_TRANSCRIPTION } from "./knowledge";

const TINY_WINDOW = 16_000;

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Body = any;

/** The routes besides the chat: the model list and image generation; else 404. */
async function otherRoute(req: Request, path: string): Promise<Response> {
  if (req.method === "GET" && path === "/models") {
    return Response.json({ data: [{ id: "mock-large", context_length: 64_000 }, { id: "mock-small" }, { id: "mock-tiny" }] });
  }
  if (req.method !== "POST" || path !== "/images/generations") {
    return Response.json({ error: { message: "Not found" } }, { status: 404 });
  }
  const body = await req.json();
  if (!body.model || !body.prompt) return Response.json({ error: { message: "model and prompt are required" } }, { status: 400 });
  return Response.json({ created: 0, data: [{ b64_json: MOCK_PNG }] });
}

/** A request the chat refuses: an option the strict endpoint doesn't know, or too many tokens
 *  for mock-tiny. */
function refused(body: Body, strict: boolean, tokens: number): Response | null {
  if (strict && body.stream_options) {
    const detail = [{ type: "extra_forbidden", loc: ["body", "stream_options"], msg: "Extra inputs are not permitted" }];
    return Response.json({ object: "error", message: { detail } }, { status: 422 });
  }
  if (body.model !== "mock-tiny" || tokens <= TINY_WINDOW) return null;
  const message = `This model's maximum context length is ${TINY_WINDOW} tokens. However, your messages resulted in ${tokens} tokens.`;
  return Response.json({ error: { message } }, { status: 400 });
}

/** The streamed answer with the tokens used in a chunk of their own, before the end. */
async function withUsage(res: Response, tokens: number): Promise<Response> {
  const usage = `data: ${JSON.stringify({ choices: [], usage: { prompt_tokens: tokens, completion_tokens: 10 } })}\n\n`;
  const text = (await res.text()).replace("data: [DONE]", usage + "data: [DONE]");
  return new Response(text, { headers: { "content-type": "text/event-stream" } });
}

export async function mockAi(req: Request): Promise<Response> {
  const pathname = new URL(req.url).pathname;
  const path = pathname.replace(/^.*\/v1(\/strict)?/, "");
  if (req.method !== "POST" || path !== "/chat/completions") return otherRoute(req, path);
  const body = await req.json();
  const tokens = Math.ceil(JSON.stringify([body.messages, body.tools ?? []]).length / 4);
  const refusal = refused(body, /\/v1\/strict\//.test(pathname), tokens);
  if (refusal) return refusal;
  const res = await respond(req, body);
  const usage = body.stream_options?.include_usage && body.stream && res.ok;
  return usage ? withUsage(res, tokens) : res;
}

/** The conversation condensed: how often it looked so far. */
function condense(t: Turn) {
  const input = textOf(t.last.content);
  const before = Number(/Looked (\d+) times/.exec(input)?.[1] ?? 0);
  const n = before + (input.match(/^Result of get_calendar/gm)?.length ?? 0);
  return reply(t.stream, `Looked ${n} times. Condensed: ${input.length} characters.`);
}

/** The features' own prompts, by how their instructions start (see their files). */
const PROMPTS: [string, (t: Turn) => Response][] = [
  ["You condense a conversation", condense],
  ["You are a professional recipe creator", (t) => recipes(t.stream, t.system)],
  ["You are a professional recipe editor", (t) => importRecipe(t.stream, t.system)],
  ["You find the events, tasks and deadlines in a letter", (t) => letter(t.stream, t.system, textOf(t.last.content))],
  ["You write a card for a document", (t) => card(t.stream, t.system, textOf(t.last.content))],
  ["You transcribe one scanned page", (t) => transcription(t.stream, t.last)],
  ["You read photos of pages of a German vaccination booklet", (t) => healthScan(t.stream, t.system, t.last)],
  [
    "You sort bank transactions into categories.",
    (t) => categorize(t.stream, t.system, t.messages, t.tools.has("web_search") && t.toolChoice !== "none"),
  ],
];

function turnOf(req: Request, body: Body): Turn {
  const messages: Msg[] = body.messages ?? [];
  const system = textOf(messages[0]?.content);
  const text = textOf(messages.at(-1)!.content);
  return {
    req,
    stream: body.stream === true,
    messages,
    last: messages.at(-1)!,
    system,
    asked: textOf(messages.findLast((m) => m.role === "user")?.content ?? ""),
    text,
    lower: text.toLowerCase(),
    tools: new Set((body.tools ?? []).map((t: { function: { name: string } }) => t.function.name)),
    toolChoice: body.tool_choice,
    today: /Today is (\d{4}-\d{2}-\d{2})/.exec(system)?.[1] ?? new Date().toISOString().slice(0, 10),
    dates: text.match(/\d{4}-\d{2}-\d{2}/g) ?? [],
  };
}

/** The pages a device sent for view_knowledge_pages (a message of their own after the result). */
function pagesSeen(t: Turn) {
  if (t.last.role !== "user" || !t.text.startsWith("[Pages for view_knowledge_pages")) return null;
  const n = Array.isArray(t.last.content) ? t.last.content.filter((p) => p.type === "image_url").length : 0;
  return reply(t.stream, `Saw ${n} pages: ${t.text.split("\n")[0]}`);
}

async function respond(req: Request, body: Body): Promise<Response> {
  const t = turnOf(req, body);
  const prompt = PROMPTS.find(([start]) => t.system.startsWith(start));
  if (prompt) return prompt[1](t);
  for (const step of PACING) {
    const res = await step(t);
    if (res) return res;
  }
  const pages = pagesSeen(t);
  if (pages) return pages;
  if (t.last.role === "tool") return afterToolResult(t.stream, t.messages, t.asked);
  for (const command of COMMANDS) {
    const res = await command(t);
    if (res) return res;
  }
  return echo(t);
}
