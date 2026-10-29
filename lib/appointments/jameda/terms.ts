// Jameda term suggestions (Fachgebiet / Leistung / Erkrankung).
//
// Jameda's live autocomplete is Algolia-backed and auth/referer-locked, so we ship a
// static dataset harvested from Jameda's own directory pages (see
// scripts/harvest-jameda-terms.ts) and filter it in-memory. This keeps the autocomplete
// offline, deterministic, and independent of Jameda being reachable at query time.

import type { JamedaTermType } from "./client";
import data from "./terms-data.json";

export interface JamedaTerm {
  slug: string;
  label: string;
  type: JamedaTermType;
}

// Anchors on a directory index point at absolute /<section>/<slug> URLs with a single
// path segment; city links carry a second segment and are excluded by [a-z0-9-]+.
function anchorRe(section: string): RegExp {
  return new RegExp(
    `<a\\b[^>]*href="https://www\\.jameda\\.de/${section}/([a-z0-9-]+)"[^>]*>([\\s\\S]*?)</a>`,
    "gi",
  );
}

/** Decode the handful of HTML entities that appear in Jameda anchor text. */
export function decodeEntities(s: string): string {
  return s
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#0*39;|&apos;/g, "'").replace(/&nbsp;/g, " ");
}

/** Strip tags, decode entities, and collapse whitespace in anchor inner text. */
export function cleanLabel(inner: string): string {
  return decodeEntities(inner.replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ").trim();
}

/** Pure: parse a Jameda directory-index page into de-duped typed terms. */
export function parseDirectoryIndex(
  html: string,
  section: "leistungen" | "erkrankungen",
  type: JamedaTermType,
): JamedaTerm[] {
  const out: JamedaTerm[] = [];
  const seen = new Set<string>();
  for (const m of html.matchAll(anchorRe(section))) {
    const slug = m[1];
    const label = cleanLabel(m[2]);
    // Skip A–Z alphabet nav links (single-char slugs) and blank/duplicate entries.
    if (!label || slug.length < 2 || seen.has(slug)) continue;
    seen.add(slug);
    out.push({ slug, label, type });
  }
  return out;
}

/** Pure: case-insensitive substring match on slug + label. Empty query → []. */
export function filterTerms(items: JamedaTerm[], query: string, limit = 20): JamedaTerm[] {
  const q = query.trim().toLowerCase();
  if (!q) return [];
  return items
    .filter((i) => i.slug.includes(q) || i.label.toLowerCase().includes(q))
    .slice(0, limit);
}

const TERMS = data as JamedaTerm[];

export function suggestJamedaTerms(query: string, limit = 20): JamedaTerm[] {
  return filterTerms(TERMS, query, limit);
}
