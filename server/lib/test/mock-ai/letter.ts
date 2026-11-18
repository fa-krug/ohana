// Asked to read a letter (the letter prompt, POST /ai/letter), it answers with JSON in a Markdown
// block: source "Elternbrief" (the letter's first line), an event in 7 days 15:00–17:00 in the
// schoolyard for the family's first member, a task due in 5 days and a deadline in 3 days at
// 12:00 (German titles when asked to answer in German). A letter saying "nothing" gets no items;
// one saying "sloppy" gets wrong items too (no date, end without start, unknown kind …). Its
// filing: the source as title, today as date, the first member as person, the first two of the
// existing tags and a made-up one.

import { reply } from "./reply";

/** The letter prompt: a few items relative to the prompt's today (see the top). */
export function letter(stream: boolean, system: string, text: string) {
  const today = /^Today is \w+, (\d{4}-\d{2}-\d{2})\./m.exec(system)?.[1] ?? new Date().toISOString().slice(0, 10);
  const de = /^Answer in German/m.test(system);
  const first = /^The family's members[^:]*: ([^,(.]+)/m.exec(system)?.[1]?.trim();
  const day = (n: number) => {
    const d = new Date(today + "T00:00:00Z");
    d.setUTCDate(d.getUTCDate() + n);
    return d.toISOString().slice(0, 10);
  };
  const source = text.trim().split("\n")[0].slice(0, 80) || "Elternbrief";
  const given = /^- "tags": up to \d+ of the existing tags .*\(JSON\): (\[.*?\])\. A tag/m.exec(system)?.[1];
  const tags: string[] = given ? JSON.parse(given) : [];
  const filing = {
    title: source,
    date: today,
    ...(first ? { person: first } : {}),
    tags: [...tags.slice(0, 2), "Made up"],
  };
  if (/\bnothing\b/i.test(text)) return reply(stream, JSON.stringify({ source, items: [], filing }));
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
  return reply(stream, "Here is what I found:\n```json\n" + JSON.stringify({ source, items, filing }, null, 1) + "\n```");
}
