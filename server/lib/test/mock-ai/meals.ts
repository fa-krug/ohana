// Asked for recipes (the meals generator's prompt) it answers with that many recipes as JSON in
// a Markdown block; POST /images/generations answers with a small PNG (b64_json).
// Asked to import a web page's recipe (the import prompt), it answers with one recipe titled
// like the page (tomatoes and the family's tags the page names) when the page mentions
// ingredients / Zutaten / recipe / Rezept, else with [].

import { reply } from "./reply";

/** A 16×16 orange PNG: the mock's "photo". */
export const MOCK_PNG =
  "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAACXBIWXMAAAPoAAAD6AG1e1JrAAAAGUlEQVR4nGO4U6FBEmIY1VAxGkp3hmvSAAC5KnwQ90HjsgAAAABJRU5ErkJggg==";

/** The recipe generator's prompt: `count` recipes as JSON in a Markdown block (the first
 *  required tag, if any, on each). */
export function recipes(stream: boolean, prompt: string) {
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
export function importRecipe(stream: boolean, prompt: string) {
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
