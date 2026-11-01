// Reading a letter (POST /ai/letter): the app's letter scan (a school letter, an invitation, a
// closure notice …) sends the letter's text once and gets the events, tasks and deadlines in it,
// which its review sheet lists for the user to edit and add. One completion with the family's
// model (no chat, no tools); the answer is JSON whose items are checked one by one like
// suggest_items' (tools/suggestions.ts resolveSuggestion): a wrong one is dropped, never the
// whole answer. Tasks and deadlines go to the device's default Reminders list (list null).

import { HttpError } from "@/lib/api/http";
import { isValidDate } from "@/lib/calendar/dates";
import { ageOn } from "@/lib/families/birthdays";
import { extractJson } from "@/lib/meals/ai/verify";
import type { NetOptions } from "./net";
import { type Provider, streamChat } from "./provider";
import { MAX_SOURCE, MAX_SUGGESTIONS, resolveSuggestion, type SuggestionOp } from "./tools/suggestions";

/** The letter's text the route takes at most (characters). */
export const MAX_LETTER_TEXT = 100_000;
export const LETTER_TIMEOUT_MS = 90_000;
/** The model copies what the letter says; it doesn't invent. */
const LETTER_TEMPERATURE = 0.2;

export interface LetterInput {
  text: string;
  today: string;
  lang: "en" | "de";
}

export interface LetterResult {
  source?: string;
  items: SuggestionOp[];
}

/** POST /ai/letter's body {text, today?, lang?}: `today` defaults to `now`'s (UTC) day. */
export function letterInput(body: Record<string, unknown>, now: Date): LetterInput {
  const text = typeof body.text === "string" ? body.text.trim() : "";
  if (!text) throw new HttpError(400, "text is required");
  if (text.length > MAX_LETTER_TEXT) throw new HttpError(400, `text takes at most ${MAX_LETTER_TEXT} characters`);
  let today = now.toISOString().slice(0, 10);
  if (body.today !== undefined && body.today !== null) {
    if (!isValidDate(body.today)) throw new HttpError(400, "today must be YYYY-MM-DD");
    today = body.today;
  }
  return { text, today, lang: body.lang === "de" ? "de" : "en" };
}

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/** The instructions: the day, the answer's language, the family (so `person` names the right
 *  one) and the JSON to answer with. The letter itself is the user message. */
export function letterPrompt({
  today,
  lang,
  people,
}: {
  today: string;
  lang: "en" | "de";
  people: { name: string; birthday: string | null }[];
}): string {
  const weekday = WEEKDAYS[new Date(`${today}T00:00:00Z`).getUTCDay()];
  const names = people.map((p) =>
    p.birthday && p.birthday <= today ? `${p.name} (${ageOn(p.birthday, today)})` : p.name,
  );
  const language = lang === "de" ? "German" : "English";
  return [
    "You find the events, tasks and deadlines in a letter a family received (a letter from school or nursery, an invitation, a closure notice, a club's note …), so they can add them to their calendar and to-do list.",
    `Today is ${weekday}, ${today}.`,
    names.length
      ? `The family's members (with their age when known): ${names.join(", ")}.`
      : "The family's members aren't known.",
    `Answer in ${language}: titles and notes in ${language}; names, places and the letter's own terms stay as written.`,
    "",
    "Find:",
    '- "event": a dated happening (a school party, a parents\' evening, a trip, a day the school or nursery is closed). With "start" and "end" (HH:MM) when the letter gives the times, else all day (leave them out). Several days: "endDate" (the last day; "end" is the time on it).',
    '- "task": something to bring, buy, prepare or sign. "date" (and "start" for a time) when it is due by a day.',
    '- "deadline": something to reply, register, pay or hand in by a date. Only with that date ("date", "start" for a time).',
    "Resolve relative dates (\"next Monday\", \"in two weeks\", \"am Freitag\") against the letter's own date when it has one, else against today; a date without a year is its next occurrence. Leave out what is already past unless it is clearly still relevant.",
    '"person": the family member it is for, written exactly as listed above, only when the letter clearly says (e.g. the child the letter is about); else leave it out. "location" where it takes place, when given.',
    `Short titles (e.g. "Sports day", "Bring a cake", "Return the consent form"); details belong in "note". Don't invent anything the letter doesn't say. At most ${MAX_SUGGESTIONS} items, the most important first.`,
    "",
    "Answer only with JSON, no other text:",
    '{"source": "what the document is, e.g. Parents\' letter class 3b", "items": [{"kind": "event" | "task" | "deadline", "title": "…", "date": "YYYY-MM-DD", "endDate": "YYYY-MM-DD", "start": "HH:MM", "end": "HH:MM", "location": "…", "person": "…", "note": "…"}]}',
    'Leave out the fields that don\'t apply. Nothing to add: {"source": "…", "items": []}.',
  ].join("\n");
}

/** The model's answer, checked: the items that are valid (at most MAX_SUGGESTIONS), the
 *  document's name when it gave one. An answer that isn't JSON is a 502. */
export function parseLetterAnswer(content: string): LetterResult {
  let data: unknown;
  try {
    data = extractJson(content);
  } catch {
    throw new HttpError(502, "The AI model's answer was not valid JSON");
  }
  const obj = data && typeof data === "object" && !Array.isArray(data) ? (data as Record<string, unknown>) : {};
  const raw = Array.isArray(data) ? data : Array.isArray(obj.items) ? obj.items : [];
  const items: SuggestionOp[] = [];
  for (const item of raw) {
    if (items.length >= MAX_SUGGESTIONS) break;
    try {
      items.push(resolveSuggestion({}, item, { defaultList: true }));
    } catch {
      // A wrong item is left out.
    }
  }
  const source = typeof obj.source === "string" ? obj.source.trim().slice(0, MAX_SOURCE).trim() : "";
  return { ...(source ? { source } : {}), items };
}

/** One completion with the family's model for the letter; aborted with `signal` or after
 *  LETTER_TIMEOUT_MS. */
export async function readLetter(
  p: Provider,
  input: LetterInput,
  people: { name: string; birthday: string | null }[],
  net: NetOptions,
  signal?: AbortSignal,
): Promise<LetterResult> {
  const sig = AbortSignal.any([AbortSignal.timeout(LETTER_TIMEOUT_MS), ...(signal ? [signal] : [])]);
  const system = letterPrompt({ today: input.today, lang: input.lang, people });
  let content = "";
  try {
    for await (const ev of streamChat(
      p,
      {
        messages: [
          { role: "system", content: system },
          { role: "user", content: input.text },
        ],
        temperature: LETTER_TEMPERATURE,
      },
      net,
      sig,
    )) {
      if (ev.type === "done") content = ev.content;
    }
  } catch (err) {
    if (err instanceof HttpError) throw err;
    throw new HttpError(502, sig.aborted ? "The AI model took too long to answer" : "The AI request failed");
  }
  return parseLetterAnswer(content);
}
