// Importing one recipe from a web page with the family's AI (the app's "Import from web
// address", its Safari share extension and Shortcuts action): the page's content — the text
// the browser had, else the page fetched here — goes to the model with the import prompt
// (prompt.ts buildImportPrompt), its answer is checked like the generator's (verify.ts) and
// saved like the generator's picks (bulkCreateRecipes, list TO_TRY), with the page's address at
// the end of the description and the page's photo when it has one.
//
// Pages and photos are fetched with the net that never reaches private addresses (also not
// with AI_ALLOW_PRIVATE_ENDPOINT, which is only for the model), with timeouts and size limits.
// A photo that can't be had never fails the import.

import { z } from "zod";
import { HttpError } from "@/lib/api/http";
import { decodeEntities, htmlToText, type NetOptions, readLimited, safeFetch } from "@/lib/assistant/net";
import type { Provider } from "@/lib/assistant/provider";
import type { Db } from "@/lib/db";
import { Decimal, quantize2 } from "@/lib/meals/domain/decimal";
import { processToWebp } from "@/lib/meals/images/storage";
import { type BulkRecipeInput, type BulkStepInput, bulkCreateRecipes } from "@/lib/meals/recipes/bulk-create";
import { generateRecipeData } from "./generate";
import { type GeneratedRecipeData, type GeneratedStep, importPrompt, resolveGenerated } from "./recipes";

/** The page text the model gets at most (characters). */
export const MAX_IMPORT_TEXT = 100_000;
/** The page's schema.org Recipe data the model gets at most (characters). */
const MAX_STRUCTURED = 30_000;
/** Below this many characters the browser's text doesn't count: the page is fetched here. */
const MIN_TEXT = 100;
export const PAGE_TIMEOUT_MS = 20_000;
const IMAGE_TIMEOUT_MS = 20_000;
const MAX_PAGE_BYTES = 3_000_000;
const MAX_IMAGE_BYTES = 10_000_000;
/** The model copies; it doesn't invent. */
const IMPORT_TEMPERATURE = 0.2;
const USER_AGENT = "Mozilla/5.0 (compatible; Ohana/1.0; +https://ohana.fa-krug.de)";

function isHttpUrl(s: string): boolean {
  try {
    const u = new URL(s);
    return u.protocol === "http:" || u.protocol === "https:";
  } catch {
    return false;
  }
}

const httpUrl = z.string().trim().max(2000).refine(isHttpUrl, "url must be an http or https address");

/** POST …/meals/recipes/import's body. A text beyond MAX_IMPORT_TEXT is cut; an imageUrl that
 *  isn't http(s) is ignored (the photo is best effort). */
export const importRecipeSchema = z.object({
  url: z.string({ required_error: "url is required", invalid_type_error: "url must be a string" })
    .pipe(httpUrl),
  text: z.string().nullish().transform((s) => s?.slice(0, MAX_IMPORT_TEXT) ?? ""),
  title: z.string().nullish().transform((s) => s?.trim().slice(0, 300) ?? ""),
  imageUrl: httpUrl.nullish().catch(null).transform((s) => s ?? null),
});
export type ImportRecipeInput = z.infer<typeof importRecipeSchema>;

/** What the model gets of a page. */
export interface PageContent {
  title: string;
  text: string;
  /** The page's schema.org Recipe JSON-LD ("" without). */
  structuredData: string;
  /** The recipe's photo: JSON-LD's image, else og:image / twitter:image (absolute). */
  imageUrl: string | null;
}

// ---- reading HTML (pure) ----

const LD_JSON_RE = /<script\b[^>]*\btype\s*=\s*["']?application\/ld\+json["']?[^>]*>([\s\S]*?)<\/script>/gi;
const META_RE = /<meta\b[^>]*>/gi;
const ATTR_RE = /([a-zA-Z_:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/g;
/** Parts of a Recipe the model doesn't need (and that can be long). */
const SKIP_KEYS = new Set(["review", "reviews", "comment", "aggregateRating", "video", "publisher", "potentialAction", "interactionStatistic"]);

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Json = any;

function isRecipe(node: Json): boolean {
  const type = node?.["@type"];
  const types: unknown[] = Array.isArray(type) ? type : [type];
  return types.some((t) => typeof t === "string" && /(^|[:/])recipe$/i.test(t));
}

/** The Recipe nodes of a JSON-LD value (at the top, in arrays, in @graph, as mainEntity). */
function recipeNodes(value: Json, depth = 0, out: Json[] = []): Json[] {
  if (depth > 6 || !value || typeof value !== "object") return out;
  if (Array.isArray(value)) {
    for (const v of value) recipeNodes(v, depth + 1, out);
    return out;
  }
  if (isRecipe(value)) {
    out.push(value);
    return out;
  }
  for (const key of ["@graph", "mainEntity", "mainEntityOfPage", "itemListElement", "item"]) {
    if (key in value) recipeNodes(value[key], depth + 1, out);
  }
  return out;
}

function withoutNoise(node: Json): Json {
  return JSON.parse(JSON.stringify(node, (k, v) => (SKIP_KEYS.has(k) ? undefined : v)));
}

/** The first image URL of a JSON-LD image value (a string, an ImageObject or a list of either). */
function imageOf(value: Json): string | null {
  if (!value) return null;
  if (typeof value === "string") return value;
  if (Array.isArray(value)) {
    for (const v of value) {
      const found = imageOf(v);
      if (found) return found;
    }
    return null;
  }
  if (typeof value === "object") return imageOf(value.url ?? value.contentUrl ?? value["@id"]);
  return null;
}

function absolute(raw: string | null | undefined, base: string): string | null {
  if (!raw?.trim()) return null;
  try {
    const u = new URL(decodeEntities(raw.trim()), base);
    return u.protocol === "http:" || u.protocol === "https:" ? u.href : null;
  } catch {
    return null;
  }
}

/** The meta tags' content by property / name (lower case; the first of each). */
function metaOf(html: string): Map<string, string> {
  const meta = new Map<string, string>();
  for (const tag of html.match(META_RE) ?? []) {
    const attrs = new Map<string, string>();
    for (const m of tag.matchAll(ATTR_RE)) attrs.set(m[1].toLowerCase(), m[2] ?? m[3] ?? m[4] ?? "");
    const key = (attrs.get("property") ?? attrs.get("name") ?? "").toLowerCase();
    const content = attrs.get("content");
    if (key && content !== undefined && !meta.has(key)) meta.set(key, decodeEntities(content).trim());
  }
  return meta;
}

/** What an HTML page gives the import: its Recipe JSON-LD (read before the scripts go), its
 *  readable text, its title and the recipe's photo. `pageUrl` resolves relative image URLs. */
export function extractPage(html: string, pageUrl: string): PageContent {
  const recipes: Json[] = [];
  for (const m of html.matchAll(LD_JSON_RE)) {
    const raw = m[1].trim().replace(/^<!--|-->$/g, "").replace(/^\/\/\s*<!\[CDATA\[|\/\/\s*\]\]>$/g, "").trim();
    try {
      recipeNodes(JSON.parse(raw), 0, recipes);
    } catch {
      // Not JSON: left out.
    }
  }
  const meta = metaOf(html);
  const { title, text } = htmlToText(html);
  const firstName = recipes.map((r) => r.name).find((n) => typeof n === "string" && n.trim());
  const imageUrl =
    absolute(imageOf(recipes[0]?.image), pageUrl) ??
    absolute(meta.get("og:image") ?? meta.get("og:image:url") ?? meta.get("og:image:secure_url"), pageUrl) ??
    absolute(meta.get("twitter:image") ?? meta.get("twitter:image:src"), pageUrl);
  return {
    title: (meta.get("og:title") || (firstName ? decodeEntities(String(firstName)).trim() : "") || title).slice(0, 300),
    text: text.slice(0, MAX_IMPORT_TEXT),
    structuredData: recipes.map((r) => JSON.stringify(withoutNoise(r))).join("\n").slice(0, MAX_STRUCTURED),
    imageUrl,
  };
}

/** Whether the browser handed over the page's HTML rather than its text. */
function looksLikeHtml(s: string): boolean {
  return /<(html|body|head|script|div|article|main)\b/i.test(s.slice(0, 5000));
}

// ---- the network ----

/** Never private addresses: pages and photos come from anywhere a user points us. */
const publicNet = (net: NetOptions): NetOptions => ({ ...net, allowPrivate: false });

/** Fetches a page and reads it (extractPage for HTML). 400 for a private or invalid address,
 *  502 when it can't be loaded. */
export async function fetchPage(url: string, net: NetOptions, signal?: AbortSignal): Promise<PageContent> {
  let res: Response;
  try {
    res = await safeFetch(url, {
      headers: {
        accept: "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5",
        "user-agent": USER_AGENT,
      },
      signal,
      timeoutMs: PAGE_TIMEOUT_MS,
    }, publicNet(net));
  } catch (err) {
    if (err instanceof HttpError) throw err;
    throw new HttpError(502, signal?.aborted ? "The import was cancelled" : "The page couldn't be loaded");
  }
  if (!res.ok) {
    await res.body?.cancel().catch(() => {});
    throw new HttpError(502, `The page answered ${res.status}`);
  }
  const type = (res.headers.get("content-type") ?? "").toLowerCase();
  if (type && !/html|xml|text\//.test(type)) {
    await res.body?.cancel().catch(() => {});
    throw new HttpError(502, `Can't read ${type.split(";")[0]}`);
  }
  let raw: string;
  try {
    raw = await readLimited(res, MAX_PAGE_BYTES);
  } catch {
    throw new HttpError(502, "The page couldn't be loaded");
  }
  if (type.includes("html") || looksLikeHtml(raw)) return extractPage(raw, res.url || url);
  return { title: "", text: raw.slice(0, MAX_IMPORT_TEXT), structuredData: "", imageUrl: null };
}

/** At most `max` bytes of a response; null when it is bigger. */
async function readBytes(res: Response, max: number): Promise<Buffer | null> {
  if (!res.body) return null;
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > max) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks);
}

/** A photo as WebP (processToWebp), or null when it can't be had: never throws. */
export async function downloadImage(url: string, net: NetOptions, signal?: AbortSignal): Promise<Buffer | null> {
  try {
    const res = await safeFetch(url, {
      headers: { accept: "image/*", "user-agent": USER_AGENT },
      signal,
      timeoutMs: IMAGE_TIMEOUT_MS,
    }, publicNet(net));
    const type = (res.headers.get("content-type") ?? "").toLowerCase();
    if (!res.ok || /text|json|xml/.test(type)) {
      await res.body?.cancel().catch(() => {});
      return null;
    }
    const length = Number(res.headers.get("content-length") ?? 0);
    if (length > MAX_IMAGE_BYTES) {
      await res.body?.cancel().catch(() => {});
      return null;
    }
    const bytes = await readBytes(res, MAX_IMAGE_BYTES);
    return bytes?.length ? await processToWebp(bytes) : null;
  } catch {
    return null;
  }
}

// ---- the import ----

/** The page as the model gets it: the browser's text (or HTML) when it is enough, else the
 *  page fetched here. A title the browser sent wins. */
export async function pageOf(input: ImportRecipeInput, net: NetOptions, signal?: AbortSignal): Promise<PageContent> {
  let page: PageContent;
  if (input.text.trim().length >= MIN_TEXT) {
    page = looksLikeHtml(input.text)
      ? extractPage(input.text, input.url)
      : { title: "", text: input.text, structuredData: "", imageUrl: null };
  } else {
    page = await fetchPage(input.url, net, signal);
  }
  return { ...page, title: input.title || page.title };
}

function quantityOf(q: number | string | undefined): string {
  if (q === undefined || q === "") return "1";
  try {
    const d = quantize2(new Decimal(q));
    return d.isZero() ? String(q) : d.toString();
  } catch {
    return String(q);
  }
}

function stepOf(s: GeneratedStep, i: number): BulkStepInput {
  return {
    stepNumber: s.step_number ?? i + 1,
    instruction: s.instruction ?? "",
    programType: s.program_type || undefined,
    temperature: s.temperature ?? null,
    durationSeconds: s.duration_seconds ?? null,
    speed: s.speed ?? null,
    turbo: s.turbo ?? false,
    direction: s.direction ?? "",
    weightGrams: s.weight_grams ?? null,
  };
}

/** A resolved recipe as bulkCreateRecipes takes it, the source at the end of the description. */
export function toBulkRecipe(data: GeneratedRecipeData, sourceUrl: string, webp: Buffer | null): BulkRecipeInput {
  return {
    title: data.title,
    description: [data.description?.trim(), `Source: ${sourceUrl}`].filter(Boolean).join("\n\n"),
    defaultServings: data.default_servings ?? 2,
    prepTimeMinutes: data.prep_time_minutes ?? null,
    cookTimeMinutes: data.cook_time_minutes ?? null,
    leftoverDays: data.leftover_days ?? null,
    ingredients: (data.ingredients ?? []).map((i, idx) => ({
      nameEn: i.name_en,
      nameDe: i.name_de,
      category: i.category ?? "OTHER",
      quantity: quantityOf(i.quantity),
      unitAbbreviation: i.unit_abbreviation ?? "",
      order: i.order ?? idx,
    })),
    manualSteps: (data.manual_steps ?? []).map(stepOf),
    machineSteps: (data.machine_steps ?? []).map(stepOf),
    tagIds: data.tag_ids ?? [],
    imageBase64: webp ? webp.toString("base64") : null,
  };
}

export interface ImportOptions {
  db: Db;
  familyId: string;
  input: ImportRecipeInput;
  /** The user's language (the recipe is written in it). */
  language: "en" | "de";
  provider: Provider;
  /** Requests to the family's AI endpoint. */
  modelNet: NetOptions;
  /** Requests to the page and its photo (private addresses are refused regardless). */
  net: NetOptions;
  now: Date;
  signal?: AbortSignal;
}

/** Imports the page's recipe and saves it (TO_TRY). 422 when the page holds none. */
export async function importRecipe(o: ImportOptions): Promise<{ id: string; title: string }> {
  const { db, familyId, input } = o;
  const page = await pageOf(input, o.net, o.signal);
  // The photo loads while the model reads.
  const imageUrl = input.imageUrl ?? page.imageUrl;
  const photo = imageUrl ? downloadImage(imageUrl, o.net, o.signal) : Promise.resolve(null);
  const prompt = importPrompt(db, familyId, {
    language: o.language,
    url: input.url,
    title: page.title,
    structuredData: page.structuredData,
    text: page.text,
  });
  const [recipe] = await generateRecipeData(o.provider, prompt, o.modelNet, o.signal, { temperature: IMPORT_TEMPERATURE });
  if (!recipe || (!recipe.ingredients.length && !recipe.manual_steps.length && !recipe.machine_steps.length)) {
    throw new HttpError(422, "No recipe found on that page");
  }
  const data = resolveGenerated(db, familyId, recipe);
  const webp = await photo;
  // The app, the share sheet or the shortcut gave up meanwhile (the request's signal): nothing
  // is saved that nobody waits for.
  if (o.signal?.aborted) throw new HttpError(400, "The import was cancelled");
  const { createdIds } = await bulkCreateRecipes(db, familyId, { recipes: [toBulkRecipe(data, input.url, webp)] }, o.now);
  return { id: createdIds[0], title: data.title };
}
