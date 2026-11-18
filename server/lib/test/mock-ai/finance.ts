// Asked to sort transactions into categories (the categorize prompt), it picks the category
// whose id or name occurs in a standing instruction that names a word of the row's payee (4
// letters or more), else in the row's payee or description, searching the web once for a payee
// it can't place (it never takes a row's usual category: the server falls back to it).

import { type Msg, reply, textOf } from "./reply";

/** The categorize prompt: a category whose id or name occurs in a standing instruction naming
 *  the row's payee, else in its payee or description, else in what a web search for its payee
 *  found; unknown payees are searched once. */
export function categorize(stream: boolean, system: string, messages: Msg[], canSearch: boolean) {
  const [head, standing = ""] = system.split("The family's standing instructions (they come first):\n");
  const categories = [...head.matchAll(/^- ([a-z0-9-]+): (?:[^\w\s]\S* )?([^(\n]+?)(?: \(|$)/gmu)];
  const instructions = [...standing.matchAll(/^- (.+)$/gm)].map((m) => m[1].toLowerCase());
  const match = (text: string) =>
    categories.find(([, id, name]) => text.includes(id) || text.includes(name.toLowerCase()))
      ?.[1] ?? null;
  const ruled = (payee: string) => {
    const words = payee.toLowerCase().split(/\W+/u).filter((w) => w.length >= 4);
    const rule = instructions.find((i) => words.some((w) => i.includes(w)));
    return rule ? match(rule) : null;
  };
  const found = searchesFound(messages);
  const answer: Record<string, string | null> = {};
  const unknown: string[] = [];
  for (const line of textOf(messages[1].content).split("\n")) {
    const [n, , , payee = "", description = ""] = line.split(" | ");
    answer[n] = ruled(payee) ?? match(`${payee} ${description}`.toLowerCase()) ??
      match(found.get(payee) ?? "");
    if (!answer[n] && payee && !found.has(payee)) unknown.push(payee);
  }
  if (canSearch && unknown.length && !found.size) {
    return reply(stream, "", { name: "web_search", args: { query: unknown[0] } });
  }
  return reply(stream, "```json\n" + JSON.stringify(answer) + "\n```");
}

/** What the web searches so far found, by query (lower case). */
function searchesFound(messages: Msg[]): Map<string, string> {
  const found = new Map<string, string>();
  for (const m of messages.filter((m) => m.role === "tool")) {
    const result = JSON.parse(textOf(m.content));
    found.set(result.query, JSON.stringify(result.results ?? []).toLowerCase());
  }
  return found;
}
