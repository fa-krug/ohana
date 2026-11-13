// The values the family's documents report (their cards' `values`, card.ts): lab results, grades,
// readings, a statement's figures …, across documents, so the assistant can follow one over time
// ("Hämoglobin" in every blood test) or list a report's. Documents searched like search.ts's
// (ready and pending, so a card being rewritten still counts); a document's values are of its
// date unless they have their own.

import { and, eq, inArray, isNotNull, type SQL } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { kbDocuments } from "@/lib/db/schema";
import { familyNames } from "@/lib/families/people";
import { normalizeForSearch } from "@/lib/meals/domain/recipes/search";
import { type KnowledgeValue, parseJsonArray } from "./documents";

export interface ValueQuery {
  /** Words each of which begins a word of the value's name or group (case and accents ignored). */
  query?: string | null;
  documentId?: string | null;
  /** A member's id (account or person): only their documents. */
  personId?: string | null;
  /** The values' days (YYYY-MM-DD), inclusive; values without a day are left out then. */
  from?: string | null;
  to?: string | null;
}

export interface ValueHit extends KnowledgeValue {
  documentId: string;
  documentName: string;
  path: string;
  /** The value's own date, else its document's. */
  day: string | null;
  person: string | null;
}

const words = (s: string) => normalizeForSearch(s).split(/[^\p{L}\p{N}]+/u).filter(Boolean);

/** The values matching `q`, oldest day first (those without one last), then by document and in
 *  the document's order. */
export function findKnowledgeValues(db: Db, familyId: string, q: ValueQuery): ValueHit[] {
  const filters: SQL[] = [
    eq(kbDocuments.familyId, familyId),
    inArray(kbDocuments.status, ["ready", "pending"]),
    isNotNull(kbDocuments.values),
  ];
  if (q.documentId) filters.push(eq(kbDocuments.id, q.documentId));
  const docs = db
    .select({
      id: kbDocuments.id,
      name: kbDocuments.name,
      path: kbDocuments.path,
      docDate: kbDocuments.docDate,
      personUserId: kbDocuments.personUserId,
      personPersonId: kbDocuments.personPersonId,
      values: kbDocuments.values,
    })
    .from(kbDocuments)
    .where(and(...filters))
    .all();
  const names = new Map(familyNames(db, familyId).map((p) => [p.id, p.name]));
  const wanted = words(q.query ?? "");
  const out: (ValueHit & { order: number })[] = [];
  for (const d of docs) {
    const personId = d.personUserId ?? d.personPersonId;
    if (q.personId && personId !== q.personId) continue;
    for (const [order, v] of (parseJsonArray<KnowledgeValue>(d.values) ?? []).entries()) {
      if (wanted.length) {
        const have = words(`${v.name} ${v.group ?? ""}`);
        if (!wanted.every((w) => have.some((h) => h.startsWith(w)))) continue;
      }
      const day = v.date ?? d.docDate;
      if ((q.from || q.to) && !day) continue;
      if (q.from && day! < q.from) continue;
      if (q.to && day! > q.to) continue;
      out.push({
        ...v,
        documentId: d.id,
        documentName: d.name,
        path: d.path,
        day,
        person: personId ? (names.get(personId) ?? null) : null,
        order,
      });
    }
  }
  out.sort(
    (a, b) =>
      (a.day === null ? 1 : 0) - (b.day === null ? 1 : 0) ||
      (a.day ?? "").localeCompare(b.day ?? "") ||
      a.path.localeCompare(b.path) ||
      a.order - b.order,
  );
  return out.map(({ order: _, ...v }) => v);
}
