// What the mock AI says once a tool's result is back: what happened, by the tool and the result
// (a knowledge search cites its first hit, a device card tells how many changes were applied …).

import { type Msg, reply, textOf } from "./reply";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Result = any;

/** What a device card's changes are called, by its tool (default: Reminders). */
const DEVICE: Record<string, { changes: string; left: string }> = {
  edit_apple_calendar: { changes: "calendar", left: "calendars" },
  edit_knowledge_notes: { changes: "note", left: "notes" },
  edit_memories: { changes: "memory", left: "memories" },
};
const deviceOf = (tool?: string) => DEVICE[tool ?? ""] ?? { changes: "reminder", left: "Reminders" };

const applied = (r: Result) => r.results?.filter((x: { ok?: boolean }) => x.ok).length ?? 0;
const total = (r: Result) => r.results?.length ?? 0;

/** Tools with words of their own. */
const BY_TOOL: Record<string, (r: Result, asked: string) => string> = {
  search_knowledge: (r, asked) => {
    const hit = r.hits?.[0];
    const invented = /\binvent\b/i.test(asked) ? " And this too [[k:999999]]." : "";
    return hit ? `${hit.name} says: ${hit.text.slice(0, 40)} [[${hit.ref}]].${invented}` : "Nothing found in the documents.";
  },
  read_knowledge: (r) => {
    const first = r.chunks?.[0]?.ref;
    const passages = `${r.chunks?.length ?? 0} passages${first ? ` [[${first}]]` : ""}`;
    return `Read ${r.document?.name}, page ${r.page ?? "all"} of ${r.pages}: ${passages}.`;
  },
};

type Rule = [when: (r: Result, tool?: string) => unknown, say: (r: Result, tool?: string) => string];

/** Any other tool: by the shape of its result, the first rule that fits. */
const RULES: Rule[] = [
  [(r) => r.skipped, () => "You skipped my question."],
  [(r, t) => t === "suggest_items" && r.applied === true, (r) => `Added ${applied(r)} of ${total(r)} suggestions.`],
  [(r, t) => t === "suggest_items" && r.applied === false, () => "OK, I added nothing."],
  [(r) => r.applied === true, (r, t) => `Done: ${applied(r)} of ${total(r)} ${deviceOf(t).changes} changes applied.`],
  [(r) => r.applied === false, (_, t) => `OK, I left your ${deviceOf(t).left} as they were.`],
  [
    (r) => Array.isArray(r.calendars) && Array.isArray(r.events),
    (r) => `You have ${r.events.length} events in ${r.calendars.length} calendars.`,
  ],
  [
    (r) => Array.isArray(r.days) && r.days.every((d: { items?: unknown }) => Array.isArray(d.items)),
    (r) => `${r.days.reduce((n: number, d: { items: unknown[] }) => n + d.items.length, 0)} items to buy on ${r.days.length} shopping days.`,
  ],
  [
    (r) => Array.isArray(r.lists) && Array.isArray(r.items),
    (r) => `You have ${r.items.length} open reminders in ${r.lists.length} lists.`,
  ],
  [(r) => r.selected || r.ownAnswer, (r) => `You answered: ${[...(r.selected ?? []), r.ownAnswer].filter(Boolean).join(", ")}.`],
  [(r) => r.changed !== undefined, (r) => `Done: ${r.changed} days changed.`],
  [
    (r) => r.results?.[0]?.expression !== undefined,
    (r) => r.results.map((x: Result) => `${x.expression} = ${x.value ?? x.error}`).join("; "),
  ],
  [(r) => r.groups, (r) => `${r.groupCount} groups, ${r.total.expense} spent.`],
  [(r) => r.results, (r) => `I found ${r.results.length} results, e.g. ${r.results[0]?.title ?? "nothing"}.`],
  [(r) => r.ok === true && r.title, (r) => `Done: “${r.title}”.`],
  [(r) => r.ok === true && r.iterationId, (r) => `Planned ${r.meals.length} meals from ${r.from}.`],
  [(r) => r.ok === true && r.name, (r) => `Search “${r.name}” is set up.`],
  [(r) => r.ok === true, () => "Done."],
  [(r) => r.title !== undefined, (r) => `The page is called “${r.title}”.`],
  [(r) => typeof r.income === "number", (r) => `Income ${r.income}, expenses ${r.expense}.`],
];

/** The answer to the last message, a tool result; `asked` is the user's last message. */
export function afterToolResult(stream: boolean, messages: Msg[], asked: string): Response {
  const last = messages.at(-1)!;
  const result: Result = JSON.parse(textOf(last.content) || "{}");
  const tool = messages.flatMap((m) => m.tool_calls ?? []).find((c) => c.id === last.tool_call_id)?.function.name;
  if (tool === "view_knowledge_pages") {
    return reply(stream, `No pages: ${result.declined ? "declined" : result.skipped ? "skipped" : result.error}`);
  }
  if (result.error) return reply(stream, `That didn't work: ${result.error}`);
  const own = BY_TOOL[tool ?? ""];
  if (own) return reply(stream, own(result, asked));
  const rule = RULES.find(([when]) => when(result, tool));
  return reply(stream, rule ? rule[1](result, tool) : `Here is what I found: ${JSON.stringify(result).slice(0, 200)}`);
}
