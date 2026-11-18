// Asked for a knowledge document's card (the card prompt), it answers with JSON: the summary
// "A document named <name>." ("Ein Dokument namens …" in German), the date of a line "Date: <x>"
// (as written, valid or not), the person of a line "For: <name>", and a fact per line
// "Fact: <x>" (quoting x), "Shout: <x>" (quoting x in capitals, its spaces as line breaks) or
// "Invent: <x>" (a quote the text doesn't have), a keyword per line "Keyword: <x>" and a value
// per line "Value: <name> | <value> | <unit> | <range> | <group> | <date> | <note>" (as written). A text saying "garbage" gets an answer that
// isn't JSON. (Quotes count with 3 words and 15 characters: write facts long enough.)
// Asked to transcribe a knowledge document's page scan (the transcription prompt), it answers
// with a Markdown timetable in a ``` fence, or with what follows a line "Transcribe: <x>" in the
// OCR hint (as written, "\n" a line break; "Transcribe: nothing" an empty answer). Without a
// picture in the message it refuses (400: a model that takes no images).

import { type Msg, refusesWithoutImage, reply, textOf } from "./reply";

/** The card prompt: from the document's lines (see the top). */
export function card(stream: boolean, system: string, message: string) {
  if (/\bgarbage\b/i.test(message)) return reply(stream, "Sorry, I can't make a card of that.");
  const de = /^Write in German/m.test(system);
  const name = /^Name: (.*)$/m.exec(message)?.[1] ?? "?";
  const lines = message.split("\n").map((l) => l.trim());
  const value = (key: string) => lines.find((l) => l.startsWith(`${key}: `))?.slice(key.length + 2) ?? null;
  const facts: { text: string; quote: string }[] = [];
  for (const line of lines) {
    const m = /^(Fact|Shout|Invent): (.+)$/.exec(line);
    if (!m) continue;
    const quote = m[1] === "Shout" ? m[2].toUpperCase().replace(/ /g, "\n ") : m[1] === "Invent" ? `${m[2]} (as nobody wrote)` : m[2];
    facts.push({ text: `${m[1]} ${facts.length + 1}`, quote });
  }
  // "Value: <name> | <value> | <unit> | <range> | <group> | <date> | <note>" (parts after the
  // value optional, "-" for none).
  const values = lines
    .filter((l) => l.startsWith("Value: "))
    .map((l) => {
      const [vName, v, unit, range, group, date, note] = l.slice("Value: ".length).split("|").map((x) => x.trim());
      const opt = (x?: string) => (x && x !== "-" ? x : null);
      return { name: vName, value: v, unit: opt(unit), range: opt(range), group: opt(group), date: opt(date), note: opt(note) };
    });
  const answer = {
    summary: de ? `Ein Dokument namens ${name}.` : `A document named ${name}.`,
    date: value("Date"),
    person: value("For"),
    keywords: lines.filter((l) => l.startsWith("Keyword: ")).map((l) => l.slice("Keyword: ".length)),
    facts,
    values,
  };
  return reply(stream, "```json\n" + JSON.stringify(answer, null, 1) + "\n```");
}

/** The answer to a page scan (see the top). */
export const MOCK_TRANSCRIPTION = "| Stunde | Montag | Dienstag |\n| --- | --- | --- |\n| 1 | Mathe | Deutsch |\n| 2 | Englisch | Sport |";

/** The transcription prompt: the page as Markdown (see the top). */
export function transcription(stream: boolean, message: Msg) {
  const refused = refusesWithoutImage(message);
  if (refused) return refused;
  const line = /^Transcribe: (.*)$/m.exec(textOf(message.content))?.[1];
  if (line === undefined) return reply(stream, "```markdown\n" + MOCK_TRANSCRIPTION + "\n```");
  return reply(stream, line === "nothing" ? "" : line.replace(/\\n/g, "\n"));
}
