// One search across the family's modules (the app's search tab, ⌘K): recipes, calendar events
// and notes, transactions, appointment searches, the people of the family and the asking
// user's assistant chats. Every word of the query has to appear in an item (case and accents
// ignored, so "lasagne" finds "Lasagne", "muller" "Müller"). Turned-off modules are left out.
// A family's data is small enough to filter here rather than in SQL (SQLite's LIKE folds only
// ASCII).

import { and, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import {
  apptSearches,
  calEvents,
  calNotes,
  chats,
  familyMembers,
  familyPeople,
  finCategories,
  finSettings,
  finTransactions,
  recipes,
  users,
} from "@/lib/db/schema";
import { normalizeForSearch } from "@/lib/meals/domain/recipes/search";
import { moduleEnabled } from "@/lib/server-info";

export const SEARCH_KINDS = ["recipe", "event", "note", "transaction", "search", "person", "chat"] as const;
export type SearchKind = (typeof SEARCH_KINDS)[number];

export interface SearchHit {
  kind: SearchKind;
  /** The item's id: a recipe's, an event's, a transaction's, a search's, a chat's, a person's
   *  (an account's user id for a member); a note's is its day. */
  id: string;
  title: string;
  /** More of the item, joined with " · " (location and person, category, the email…). */
  detail: string;
  /** "YYYY-MM-DD": the event's, note's or transaction's day, the chat's last change. */
  day: string | null;
  /** An event's start ("HH:MM"), null all day. */
  time?: string | null;
  /** A transaction's amount (negative: money going out). */
  amountCents?: number;
  /** A person's: whether they have an account (a member) or not. */
  account?: boolean;
}

export interface SearchResult {
  query: string;
  /** The family's currency, for the transactions' amounts. */
  currency: string;
  /** In `SEARCH_KINDS` order; per kind the best `limit`, then the ones nearest to `today`. */
  results: SearchHit[];
  /** How many more matched per kind than are listed. */
  more: Partial<Record<SearchKind, number>>;
}

export const SEARCH_MAX_QUERY = 100;
export const SEARCH_DEFAULT_LIMIT = 8;
export const SEARCH_MAX_LIMIT = 50;

/** Searches family `familyId` for `query` as `userId` (whose chats are searched). */
export function searchFamily(
  db: Db,
  familyId: string,
  userId: string,
  query: string,
  { today, limit = SEARCH_DEFAULT_LIMIT }: { today: string; limit?: number },
): SearchResult {
  const q = query.trim().slice(0, SEARCH_MAX_QUERY);
  const terms = normalizeForSearch(q).split(/\s+/).filter(Boolean);
  const currency = moduleEnabled("finance")
    ? (db.select({ c: finSettings.currency }).from(finSettings).where(eq(finSettings.familyId, familyId)).get()?.c ??
      "EUR")
    : "EUR";
  if (terms.length === 0) return { query: q, currency, results: [], more: {} };

  const phrase = terms.join(" ");
  const ranked = (hits: { hit: SearchHit; text: string[] }[]): SearchHit[] =>
    hits
      .flatMap(({ hit, text }) => {
        const score = scoreOf(hit, text, terms, phrase);
        return score > 0 ? [{ hit, score }] : [];
      })
      .sort((a, b) => b.score - a.score || distance(a.hit.day, today) - distance(b.hit.day, today))
      .map((s) => s.hit);

  const groups: Record<SearchKind, SearchHit[]> = {
    recipe: moduleEnabled("meals") ? ranked(recipeHits(db, familyId)) : [],
    event: ranked(eventHits(db, familyId)),
    note: ranked(noteHits(db, familyId)),
    transaction: moduleEnabled("finance") ? ranked(transactionHits(db, familyId)) : [],
    search: moduleEnabled("appointments") ? ranked(appointmentSearchHits(db, familyId)) : [],
    person: ranked(personHits(db, familyId)),
    chat: moduleEnabled("assistant") ? ranked(chatHits(db, familyId, userId)) : [],
  };
  const results: SearchHit[] = [];
  const more: Partial<Record<SearchKind, number>> = {};
  for (const kind of SEARCH_KINDS) {
    const hits = groups[kind];
    results.push(...hits.slice(0, limit));
    if (hits.length > limit) more[kind] = hits.length - limit;
  }
  return { query: q, currency, results, more };
}

/** 0: not every term is in the item (its title, detail or `text`). The title as the phrase 4,
 *  starting with it 3, holding every term 2, else 1. */
function scoreOf(hit: SearchHit, text: string[], terms: string[], phrase: string): number {
  const t = normalizeForSearch(hit.title);
  const all = normalizeForSearch([hit.title, hit.detail, ...text].join("\n"));
  if (!terms.every((term) => all.includes(term))) return 0;
  if (t === phrase) return 4;
  if (t.startsWith(phrase)) return 3;
  return terms.every((term) => t.includes(term)) ? 2 : 1;
}

/** Days between `day` and `today`; undated items last. */
function distance(day: string | null, today: string): number {
  if (!day) return Number.MAX_SAFE_INTEGER;
  return Math.abs(Date.parse(`${day}T00:00:00Z`) - Date.parse(`${today}T00:00:00Z`)) / 86_400_000;
}

const joined = (...parts: (string | null | undefined)[]) =>
  parts
    .map((p) => p?.trim())
    .filter(Boolean)
    .join(" · ");

/** The first line of a text, at most `max` characters. */
function line(s: string, max = 120): string {
  const first = s.trim().split("\n")[0]?.trim() ?? "";
  return first.length > max ? `${first.slice(0, max - 1)}…` : first;
}

function recipeHits(db: Db, familyId: string) {
  return db
    .select({ id: recipes.id, title: recipes.title, description: recipes.description })
    .from(recipes)
    .where(eq(recipes.familyId, familyId))
    .all()
    .map((r) => ({
      hit: { kind: "recipe" as const, id: r.id, title: r.title, detail: line(r.description), day: null },
      text: [r.description],
    }));
}

function eventHits(db: Db, familyId: string) {
  return db
    .select()
    .from(calEvents)
    .where(eq(calEvents.familyId, familyId))
    .all()
    .map((e) => ({
      hit: {
        kind: "event" as const,
        id: e.id,
        title: e.title,
        detail: joined(e.location, e.person),
        day: e.day,
        time: e.start,
      },
      text: [e.location, e.person, e.note],
    }));
}

function noteHits(db: Db, familyId: string) {
  return db
    .select()
    .from(calNotes)
    .where(eq(calNotes.familyId, familyId))
    .all()
    .filter((n) => n.comment.trim())
    .map((n) => ({
      hit: { kind: "note" as const, id: n.day, title: joined(n.icon, line(n.comment)), detail: "", day: n.day },
      text: [n.comment],
    }));
}

function transactionHits(db: Db, familyId: string) {
  const categories = new Map(
    db
      .select({ id: finCategories.id, name: finCategories.name })
      .from(finCategories)
      .where(eq(finCategories.familyId, familyId))
      .all()
      .map((c) => [c.id, c.name]),
  );
  return db
    .select()
    .from(finTransactions)
    .where(eq(finTransactions.familyId, familyId))
    .all()
    .map((t) => {
      const category = t.categoryId ? categories.get(t.categoryId) : undefined;
      const title = t.payee.trim() || line(t.description) || line(t.note);
      return {
        hit: {
          kind: "transaction" as const,
          id: t.id,
          title,
          detail: joined(t.payee.trim() ? line(t.description) : "", category),
          day: t.day,
          amountCents: t.amountCents,
        },
        text: [t.description, t.note],
      };
    });
}

function appointmentSearchHits(db: Db, familyId: string) {
  return db
    .select({
      id: apptSearches.id,
      name: apptSearches.name,
      speciality: apptSearches.specialityLabel,
      jameda: apptSearches.jamedaSpecialityLabel,
      location: apptSearches.locationLabel,
    })
    .from(apptSearches)
    .where(eq(apptSearches.familyId, familyId))
    .all()
    .map((s) => ({
      hit: {
        kind: "search" as const,
        id: s.id,
        title: s.name,
        detail: joined(s.speciality || s.jameda, s.location),
        day: null,
      },
      text: [s.speciality, s.jameda, s.location],
    }));
}

function personHits(db: Db, familyId: string) {
  const members = db
    .select({ id: users.id, name: users.name, email: users.email })
    .from(familyMembers)
    .innerJoin(users, eq(users.id, familyMembers.userId))
    .where(eq(familyMembers.familyId, familyId))
    .all()
    .map((m) => ({
      hit: {
        kind: "person" as const,
        id: m.id,
        title: m.name.trim() || m.email,
        detail: m.name.trim() ? m.email : "",
        day: null,
        account: true,
      },
      text: [m.email],
    }));
  const people = db
    .select({ id: familyPeople.id, name: familyPeople.name })
    .from(familyPeople)
    .where(eq(familyPeople.familyId, familyId))
    .all()
    .map((p) => ({
      hit: { kind: "person" as const, id: p.id, title: p.name, detail: "", day: null, account: false },
      text: [],
    }));
  return [...members, ...people];
}

function chatHits(db: Db, familyId: string, userId: string) {
  return db
    .select({ id: chats.id, title: chats.title, updatedAt: chats.updatedAt })
    .from(chats)
    .where(and(eq(chats.familyId, familyId), eq(chats.userId, userId)))
    .all()
    .filter((c) => c.title.trim())
    .map((c) => ({
      hit: {
        kind: "chat" as const,
        id: c.id,
        title: c.title,
        detail: "",
        day: c.updatedAt.toISOString().slice(0, 10),
      },
      text: [],
    }));
}
