// The recipe generator's prompts: port of cookless's lib/ai/prompt.ts (the model is now the
// family's OpenAI-compatible one instead of Gemini's own API), and the import of a web page's
// recipe, which shares the output schema and the catalog sections.

export interface PromptRecipe {
  title: string;
  defaultServings: number;
  prepTimeMinutes: number | null;
  cookTimeMinutes: number | null;
  leftoverDays: number | null;
  tagNames: string[];
  ingredientLines: string[]; // e.g. "100 g Tomato"
  manualInstructions: string[];
  machineInstructions: string[];
}
export interface RecipeForSelection {
  id: string;
  tagIds: string[];
}
export interface BuildPromptArgs extends PromptCatalog {
  count: number;
  freeText: string;
  language: string;
  requiredTagIds: string[];
  referenceRecipes: PromptRecipe[];
  allTitles: string[];
}

/** Tag-matching recipes first, then fill with the rest, capped at `max`. Ports the Django query order. */
export function selectReferenceRecipes<T extends RecipeForSelection>(
  all: T[],
  requiredTagIds: string[],
  max: number,
): T[] {
  if (max <= 0) return [];
  const required = new Set(requiredTagIds);
  const matching = required.size
    ? all.filter((r) => r.tagIds.some((id) => required.has(id)))
    : [];
  const matchingIds = new Set(matching.map((r) => r.id));
  const rest = all.filter((r) => !matchingIds.has(r.id));
  return [...matching, ...rest].slice(0, max);
}

/** The catalog the prompts name: the shared ingredients and units, the family's tags. */
export interface PromptCatalog {
  ingredients: { nameEn: string; nameDe: string; category: string }[];
  units: { abbreviation: string; nameEn: string; nameDe: string }[];
  tags: { id: string; nameEn: string; nameDe: string; category: string }[];
}

const languageName = (language: string) => (language === "de" ? "German" : "English");

/** What the model answers: a JSON array of recipe objects (verify.ts checks it). */
export function outputSchemaSection(language: string, extraFields: string[] = []): string {
  const langNote = languageName(language);
  return (
    `OUTPUT SCHEMA:\n` +
    `Return a JSON array of recipe objects. Each object must have:\n` +
    `- title (string, in ${langNote})\n` +
    extraFields.map((f) => `- ${f}\n`).join("") +
    `- default_servings (integer, typically 2-4)\n` +
    `- prep_time_minutes (integer)\n` +
    `- cook_time_minutes (integer)\n` +
    `- leftover_days (integer, 0-3)\n` +
    `- ingredients (array of objects with: name_en, name_de, category ` +
    `[PRODUCE/DAIRY/MEAT/PANTRY/FROZEN/OTHER], quantity (number), ` +
    `unit_abbreviation (string), order (integer starting at 0))\n` +
    `- manual_steps (array of objects with step_number (integer) and ` +
    `instruction (string in ${langNote}))\n` +
    `- machine_steps (array of step objects for Thermomix or similar kitchen machines; can be empty.\n` +
    `  Each step is EITHER free text OR a structured program:\n` +
    `  Free text: {"step_number": 1, "instruction": "Add ingredients"}\n` +
    `  Program: {"step_number": 1, "instruction": "", "program_type": "MANUAL_COOKING", ` +
    `"temperature": 100, "duration_seconds": 300, "speed": 5, "direction": "LEFT", "turbo": false}\n` +
    `  Available programs:\n` +
    `  - MANUAL_COOKING: temperature (37-130°C), duration_seconds (1-5940), speed (1-10), direction (LEFT/RIGHT), turbo (bool, optional)\n` +
    `  - CHOPPING: duration_seconds (1-5940), speed (1-10)\n` +
    `  - KNEADING: duration_seconds (1-5940)\n` +
    `  - STEAMING: temperature (37-130°C), duration_seconds (1-5940)\n` +
    `  - BLENDING: duration_seconds (1-5940)\n` +
    `  - SEARING: temperature (37-130°C), duration_seconds (1-5940), speed (1-10)\n` +
    `  - SLOW_COOKING: temperature (37-130°C), duration_seconds (1-43200)\n` +
    `  - SOUS_VIDE: temperature (37-130°C), duration_seconds (1-43200)\n` +
    `  - WEIGHING: weight_grams (1-5000)\n` +
    `  - TURBO: duration_seconds (1-60)\n` +
    `  - EGG_COOKING: duration_seconds (1-5940)\n` +
    `  - FERMENTATION: temperature (37-60°C), duration_seconds (1-43200)\n` +
    `  - PRE_CLEANING: (no parameters)\n` +
    `  Prefer structured programs over free text when the step is a machine operation.)\n` +
    `- tag_names_en (array of strings, English tag names that apply)`
  );
}

/** EXISTING INGREDIENTS (null without any). */
export function ingredientsSection(ingredients: PromptCatalog["ingredients"]): string | null {
  if (!ingredients.length) return null;
  const lines = ingredients.map((i) => `  - ${i.nameEn} / ${i.nameDe} (${i.category})`);
  return (
    "EXISTING INGREDIENTS (use exact names when possible; " +
    "new ingredients allowed following the same pattern):\n" +
    lines.join("\n")
  );
}

/** AVAILABLE UNITS (null without any). */
export function unitsSection(units: PromptCatalog["units"]): string | null {
  if (!units.length) return null;
  return "AVAILABLE UNITS:\n" + units.map((u) => `  - ${u.abbreviation} (${u.nameEn} / ${u.nameDe})`).join("\n");
}

/** ALL AVAILABLE TAGS (null without any). */
export function tagsSection(tags: PromptCatalog["tags"]): string | null {
  if (!tags.length) return null;
  return "ALL AVAILABLE TAGS:\n" + tags.map((t) => `${t.nameEn} (${t.category})`).join(", ");
}

const present = (s: string | null): s is string => s !== null;

export function buildGenerationPrompt(args: BuildPromptArgs): string {
  const sections: string[] = [];

  sections.push(
    "You are a professional recipe creator. " +
      "Your task is to generate creative, delicious recipes. " +
      "Output structured JSON only.",
  );

  sections.push(outputSchemaSection(args.language));
  sections.push(...[ingredientsSection(args.ingredients), unitsSection(args.units)].filter(present));

  const required = new Set(args.requiredTagIds);
  const selectedTags = args.tags.filter((t) => required.has(t.id));
  if (selectedTags.length) {
    sections.push(
      "REQUIRED TAGS (every generated recipe MUST match these):\n" +
        selectedTags.map((t) => t.nameEn).join(", "),
    );
  }
  const all = tagsSection(args.tags);
  if (all) sections.push(all);

  if (args.referenceRecipes.length) {
    const refs = args.referenceRecipes.map((r) => {
      return (
        `  Title: ${r.title}\n` +
        `  Servings: ${r.defaultServings}\n` +
        `  Prep time: ${r.prepTimeMinutes} min\n` +
        `  Cook time: ${r.cookTimeMinutes} min\n` +
        `  Leftover days: ${r.leftoverDays}\n` +
        `  Tags: ${r.tagNames.join(", ")}\n` +
        `  Ingredients:\n` +
        r.ingredientLines.join("\n") +
        `\n  Manual steps: ${JSON.stringify(r.manualInstructions)}\n` +
        `  Machine steps: ${JSON.stringify(r.machineInstructions)}`
      );
    });
    sections.push(
      "STYLE REFERENCE (existing recipes for tone and format reference):\n" + refs.join("\n---\n"),
    );
  }

  if (args.allTitles.length) {
    sections.push(
      "Do NOT recreate or closely duplicate any of the following existing recipes. " +
        "Generate completely different recipes:\n" +
        args.allTitles.map((t) => `  - ${t}`).join("\n"),
    );
  }

  sections.push(
    "VARIETY: Vary cooking methods, main ingredients, and complexity across " +
      "the generated recipes. Avoid repeating the same protein or cooking technique.",
  );

  if (args.freeText && args.freeText.trim()) {
    sections.push(`ADDITIONAL REQUIREMENTS:\n${args.freeText.trim()}`);
  }

  sections.push(`Generate exactly ${args.count} recipes. Respond with ONLY the JSON array.`);

  return sections.join("\n\n");
}

/** What an imported page is: where it is, its title and its content (the text the browser or
 *  the server read, with the page's schema.org Recipe data when it had some). */
export interface BuildImportArgs extends PromptCatalog {
  language: string;
  url: string;
  title: string;
  /** The page's schema.org Recipe JSON-LD, if it had any. */
  structuredData: string;
  text: string;
}

/** The import's prompt: exactly one recipe from a web page, faithful to its author, in the
 *  user's language; `[]` when the page holds no recipe. */
export function buildImportPrompt(args: BuildImportArgs): string {
  const langNote = languageName(args.language);
  const sections: string[] = [
    "You are a professional recipe editor. " +
      "Your task is to convert the recipe on a web page into structured data. " +
      "Output structured JSON only.",
    outputSchemaSection(args.language, [`description (string, one or two sentences about the dish, in ${langNote})`]),
    ...[ingredientsSection(args.ingredients), unitsSection(args.units), tagsSection(args.tags)].filter(present),
    "RULES:\n" +
      `- Convert the page into exactly one recipe, written in ${langNote} (translate if the page is in another language).\n` +
      "- Keep the author's quantities, servings, times and steps faithfully; don't invent or leave out ingredients or steps.\n" +
      "- Convert the quantities to the available units (e.g. cups to ml or g, ounces to g); for ingredients without an amount (\"salt to taste\") use a small quantity in a fitting unit.\n" +
      "- machine_steps stays empty unless the page has steps for a Thermomix or similar kitchen machine.\n" +
      "- tag_names_en: only tags from ALL AVAILABLE TAGS that clearly apply.\n" +
      "- Ignore everything on the page that isn't the recipe (comments, ads, other recipes).\n" +
      "- If the page holds no recipe, answer with an empty array: []",
  ];
  const page = [`URL: ${args.url}`];
  if (args.title.trim()) page.push(`Title: ${args.title.trim()}`);
  if (args.structuredData.trim()) page.push(`Structured data (schema.org JSON-LD):\n${args.structuredData.trim()}`);
  page.push(`Text:\n${args.text.trim() || "(none)"}`);
  sections.push("WEB PAGE:\n" + page.join("\n\n"));
  sections.push("Convert the recipe of this page. Respond with ONLY the JSON array (one recipe, or [] without one).");
  return sections.join("\n\n");
}

export function buildImagePrompt(title: string, ingredientNames: string[]): string {
  const ingredients = ingredientNames.length ? ingredientNames.join(", ") : "various";
  return (
    "You are a professional food photographer. Generate a photorealistic, " +
    "appetizing overhead shot of the following dish on a clean, modern table setting with natural lighting.\n\n" +
    `Dish: ${title}\n` +
    `Key ingredients: ${ingredients}\n\n` +
    "Style: Top-down food photography, shallow depth of field, warm natural light, minimalist plating " +
    "on a white or neutral ceramic plate. No text, no watermarks, no people."
  );
}
