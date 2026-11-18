// Net counting: what transactions count as in every income / expense total. A transfer between
// the family's own accounts counts once by its net, a split booking by its parts, and within a
// category money in and out cancel out (netTotals). Also how transactions are told apart by
// payee (similarKey).

import type { FinanceStore as Store, TransactionRow } from "./store";

/** Transfer groups by transfer id, each with its legs in lead order. Only groups with at least
 *  two legs: a lone leg counts as a normal transaction. */
export type Groups = Map<string, TransactionRow[]>;

/** The parts of split bookings by booking id. */
export type Splits = Map<string, TransactionRow[]>;

/** How transactions are tied together: transfer groups and split bookings. */
export type Links = { groups: Groups; splits: Splits };

export const NO_LINKS: Links = { groups: new Map(), splits: new Map() };

/** Lead order: the earliest day first, ties by id. */
export function byLead(a: TransactionRow, b: TransactionRow): number {
  return a.day.localeCompare(b.day) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}

/** All legs of the transfer groups the rows touch: a range can cut a group apart, but it
 *  always counts as a whole. */
export async function loadGroups(
  store: Store,
  familyId: string,
  rows: TransactionRow[],
): Promise<Groups> {
  const groups: Groups = new Map();
  const ids = [...new Set(rows.flatMap((t) => t.transfer_id ? [t.transfer_id] : []))];
  if (!ids.length) return groups;
  for (const t of await store.listTransfers(familyId, ids)) {
    const legs = groups.get(t.transfer_id!) ?? [];
    legs.push(t);
    groups.set(t.transfer_id!, legs);
  }
  for (const [id, legs] of groups) {
    if (legs.length < 2) groups.delete(id);
    else legs.sort(byLead);
  }
  return groups;
}

/** All split bookings of the family with their parts (there are few). */
export async function loadSplits(store: Store, familyId: string): Promise<Splits> {
  const splits: Splits = new Map();
  for (const t of await store.listSplitParts(familyId)) {
    splits.set(t.split_of!, [...(splits.get(t.split_of!) ?? []), t]);
  }
  return splits;
}

/** The transfer groups the rows touch and all split bookings. */
export async function loadLinks(
  store: Store,
  familyId: string,
  rows: TransactionRow[],
): Promise<Links> {
  const [groups, splits] = await Promise.all([
    loadGroups(store, familyId, rows),
    loadSplits(store, familyId),
  ]);
  return { groups, splits };
}

/** The legs of the transaction's transfer group, if it is a leg of one. */
export function groupOf(t: TransactionRow, groups: Groups): TransactionRow[] | undefined {
  return t.transfer_id ? groups.get(t.transfer_id) : undefined;
}

/** What a transaction counts as: its amount, or the net (sum of the legs) of its group. */
export function netOf(t: TransactionRow, groups: Groups): number {
  const legs = groupOf(t, groups);
  return legs ? legs.reduce((sum, l) => sum + l.amount_cents, 0) : t.amount_cents;
}

/** What a split booking still counts as itself: its amount minus its parts (shipping, say). */
export function remainderOf(booking: TransactionRow, parts: TransactionRow[]): number {
  return parts.reduce((rest, p) => rest - p.amount_cents, booking.amount_cents);
}

/** Whether the transaction is a part or a booking of a split. */
export function inSplit(t: TransactionRow, splits: Splits): boolean {
  return !!t.split_of || splits.has(t.id);
}

/**
 * Net counting, used by every income / expense total. A transaction counts with its amount; a
 * transfer group counts once, by its net: on its lead leg's day, with the first category of
 * its legs (lead first), and only if the lead leg is among the rows. So moving 500 from one
 * account to another counts nothing (net 0), and only money that leaves the family (or comes
 * in) counts. A split booking's parts count with their own amounts and categories, and the
 * booking only with what is left of it, so the totals still match the statement.
 */
export function netItems(rows: TransactionRow[], { groups, splits }: Links): NetItem[] {
  const out: NetItem[] = [];
  const item = (t: TransactionRow, amountCents: number, categoryId: string | null) => ({
    day: t.day,
    amountCents,
    categoryId,
    accountId: t.account_id,
    payee: t.payee,
    description: t.description,
  });
  for (const t of rows) {
    const parts = splits.get(t.id);
    const legs = groupOf(t, groups);
    if (parts) {
      const rest = remainderOf(t, parts);
      if (rest !== 0) out.push(item(t, rest, t.category_id));
    } else if (!legs) {
      out.push(item(t, t.amount_cents, t.category_id));
    } else if (legs[0].id === t.id) {
      const net = netOf(t, groups);
      if (net === 0) continue;
      out.push(item(t, net, legs.find((l) => l.category_id)?.category_id ?? null));
    }
  }
  return out;
}

/** What one transaction (or transfer group, or what is left of a split booking) counts as;
 *  payee, description and account are those of the transaction (a group's lead leg). */
export type NetItem = {
  day: string;
  amountCents: number;
  categoryId: string | null;
  accountId: string | null;
  payee: string;
  description: string;
};

/**
 * What makes transactions "similar": the first words of the payee (or, without one, of the
 * description), without numbers, punctuation and case, so "REWE Markt 1234 Berlin" and
 * "Rewe Markt 5678 Berlin" match.
 */
export function similarKey(t: { payee: string; description: string }): string {
  const words = (s: string) =>
    s.toLowerCase().replace(/[^\p{L}\s]+/gu, " ").split(/\s+/).filter((w) => w.length > 1);
  const payee = words(t.payee);
  return (payee.length ? payee : words(t.description)).slice(0, 3).join(" ");
}

/**
 * Income and expenses of the items, with what came in and what went out within one category
 * cancelling out: a refund or a sale lowers its category's spending, and only what is left
 * counts as income or as an expense (a category that took in more than it spent counts as
 * income). Uncategorized money counts as it is. Every category works this way; there are no
 * income or expense categories.
 */
export function netTotals(items: { amountCents: number; categoryId: string | null }[]) {
  let incomeCents = 0, expenseCents = 0;
  const byCategory = new Map<string, { in: number; out: number }>();
  for (const it of items) {
    if (it.amountCents > 0) incomeCents += it.amountCents;
    else expenseCents -= it.amountCents;
    if (!it.categoryId) continue;
    const c = byCategory.get(it.categoryId) ?? { in: 0, out: 0 };
    if (it.amountCents > 0) c.in += it.amountCents;
    else c.out -= it.amountCents;
    byCategory.set(it.categoryId, c);
  }
  let overlap = 0;
  for (const c of byCategory.values()) overlap += Math.min(c.in, c.out);
  return { incomeCents: incomeCents - overlap, expenseCents: expenseCents - overlap };
}
