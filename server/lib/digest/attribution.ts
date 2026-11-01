// The week ahead (phase 11): who an event is for. An event's `person` is free text ("Max",
// "Anna & Max", "max, Ben und Oma"); it is split into names (at "," "&" "+" "/" " and " " und ")
// and each is matched against the family's people (familyNames: accounts and people without
// one), case and accents ignored: the whole name, or a first name only one of them has.
// Names that match nobody are left out; an event nobody matches is the family's ("unassigned").
// Pure.

import { normalizeForSearch } from "@/lib/meals/domain/recipes/search";
import { ageOn } from "@/lib/families/birthdays";

export interface FamilyPerson {
  id: string;
  name: string;
  account: boolean;
  birthday: string | null;
}

/** Under this age on the day: a child (needs taking places). */
export const CHILD_UNDER_AGE = 14;
/** From this age on: an adult (can drive). Accounts without a birthday count as adults. */
export const ADULT_FROM_AGE = 18;

const fold = (s: string) => normalizeForSearch(s).replace(/\s+/g, " ").trim();

/** The names in a `person` text, folded (lower case, without accents); empty parts dropped. */
export function splitNames(text: string): string[] {
  return fold(text)
    .split(/\s*(?:,|&|\+|\/|\band\b|\bund\b)\s*/)
    .map((s) => s.trim())
    .filter(Boolean);
}

/** A function from a `person` text to the ids of the people it names (in the family's order,
 *  each once); [] for nobody (unassigned). */
export function attributor(people: FamilyPerson[]): (text: string) => string[] {
  const full = new Map<string, string>();
  const first = new Map<string, string[]>();
  for (const p of people) {
    const name = fold(p.name);
    if (!name) continue;
    if (!full.has(name)) full.set(name, p.id);
    const given = name.split(" ")[0];
    first.set(given, [...(first.get(given) ?? []), p.id]);
  }
  const order = new Map(people.map((p, i) => [p.id, i]));
  const cache = new Map<string, string[]>();
  return (text: string) => {
    const hit = cache.get(text);
    if (hit) return hit;
    const ids = new Set<string>();
    for (const part of splitNames(text)) {
      const id = full.get(part) ?? (first.get(part)?.length === 1 ? first.get(part)![0] : undefined);
      if (id) ids.add(id);
    }
    const out = [...ids].sort((a, b) => order.get(a)! - order.get(b)!);
    cache.set(text, out);
    return out;
  };
}

/** The ids of the people a `person` text names. */
export function attributePeople(text: string, people: FamilyPerson[]): string[] {
  return attributor(people)(text);
}

/** Under 14 on `day` (needs a birthday). */
export function isChild(p: FamilyPerson, day: string): boolean {
  return !!p.birthday && ageOn(p.birthday, day) < CHILD_UNDER_AGE;
}

/** 18 or older on `day`, or an account without a birthday. */
export function isAdult(p: FamilyPerson, day: string): boolean {
  return p.birthday ? ageOn(p.birthday, day) >= ADULT_FROM_AGE : p.account;
}
