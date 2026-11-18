// What the mock AI says once a tool's result is back: what happened, by the tool and the result
// (a knowledge search cites its first hit, a device card tells how many changes were applied …).

import { type Msg, reply, textOf } from "./reply";

/** The answer to the last message, a tool result; `asked` is the user's last message. */
export function afterToolResult(stream: boolean, messages: Msg[], asked: string): Response {
  const last = messages.at(-1)!;
  const result = JSON.parse(textOf(last.content) || "{}");
  const viewed = messages.flatMap((m) => m.tool_calls ?? []).find((c) => c.id === last.tool_call_id);
  if (viewed?.function.name === "view_knowledge_pages") {
    return reply(stream, `No pages: ${result.declined ? "declined" : result.skipped ? "skipped" : result.error}`);
  }
  if (result.error) return reply(stream, `That didn't work: ${result.error}`);
  const called = messages.flatMap((m) => m.tool_calls ?? []).find((c) => c.id === last.tool_call_id);
  const device = called?.function.name === "edit_apple_calendar"
    ? { changes: "calendar", left: "calendars" }
    : called?.function.name === "edit_knowledge_notes"
    ? { changes: "note", left: "notes" }
    : called?.function.name === "edit_memories"
    ? { changes: "memory", left: "memories" }
    : { changes: "reminder", left: "Reminders" };
  const suggested = called?.function.name === "suggest_items";
  if (called?.function.name === "search_knowledge") {
    const hit = result.hits?.[0];
    const invented = /\binvent\b/i.test(asked) ? " And this too [[k:999999]]." : "";
    return reply(stream, hit ? `${hit.name} says: ${hit.text.slice(0, 40)} [[${hit.ref}]].${invented}` : "Nothing found in the documents.");
  }
  if (called?.function.name === "read_knowledge") {
    const first = result.chunks?.[0]?.ref;
    return reply(
      stream,
      `Read ${result.document?.name}, page ${result.page ?? "all"} of ${result.pages}: ${result.chunks?.length ?? 0} passages${first ? ` [[${first}]]` : ""}.`,
    );
  }
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
    ? `${result.groupCount} groups, ${result.total.expense} spent.`
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
    : result.income !== undefined && typeof result.income === "number"
    ? `Income ${result.income}, expenses ${result.expense}.`
    : `Here is what I found: ${JSON.stringify(result).slice(0, 200)}`;
  return reply(stream, text);
}
