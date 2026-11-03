// Storage of the calendar: family-planner's `Store` interface (the calendar part of
// _shared/store.ts) over Drizzle/SQLite, so vacation.ts works on it as it did on Supabase. Rows keep family-planner's snake_case shapes.

import { and, asc, eq, gte, inArray, lte } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { calEntries, calEntryTypes, calNotes, families, familyMembers, familyPeople } from "@/lib/db/schema";
import { memberColorHex, NEUTRAL_COLOR, typeShade } from "@/lib/families/colors";
import { type FinanceContents, replaceFinance } from "@/lib/finance/store";

export type Role = "none" | "needs_cover" | "covers" | "day_off";
export const ROLES: Role[] = ["none", "needs_cover", "covers", "day_off"];

export function isRole(v: unknown): v is Role {
  return ROLES.includes(v as Role);
}

export interface FamilyRow {
  id: string;
  name: string;
  created_at: string;
  updated_at: string;
}

export type FamilyPatch = Partial<Pick<FamilyRow, "name">>;

/** An entry type belongs to one year; each year of a family has its own set. */
export interface TypeRow {
  family_id: string;
  year: number;
  id: string; // unique within the family's year
  name: string;
  /** Whose type it is: an account's or a person's id in the family, or null (nobody). */
  member_id: string | null;
  /** Derived, never stored: the member's color, a shade of it from their second type of the
   *  year on (by position), a gray for nobody's. */
  color: string;
  role: Role;
  /** The stored icon (an SF Symbol name), or null: the role's (`icons.ts` `typeIcon`). */
  icon: string | null;
  position: number;
  /** The whole family is away from home on its days (the meal plan skips them).
   *  Optional: family-planner's rows and files have none (false). */
  away?: boolean;
}

/** A type to write: its color comes from the member, so a given one is ignored. */
export type TypeInput = Omit<TypeRow, "color"> & { color?: string };

export interface EntryRow {
  day: string;
  type_id: string;
}

/** Icon and/or comment on a day; independent of entries (no role, no coverage). */
export interface NoteRow {
  day: string;
  icon: string;
  comment: string;
}

export interface CalendarStore {
  getFamily(id: string): Promise<FamilyRow | null>;
  updateFamily(id: string, patch: FamilyPatch): Promise<void>;

  /** Types of all years, ordered by year and position. */
  listTypes(familyId: string): Promise<TypeRow[]>;
  upsertTypes(types: TypeInput[]): Promise<void>;
  /** Deletes the type and all of its day entries (which are all in its year). */
  deleteType(familyId: string, year: number, typeId: string): Promise<void>;
  listEntries(familyId: string, from?: string, to?: string): Promise<EntryRow[]>;
  addEntries(familyId: string, rows: EntryRow[]): Promise<void>;
  /** Removes entries on `days`; only the given types if `typeIds` is set. */
  removeEntries(familyId: string, days: string[], typeIds?: string[]): Promise<void>;
  listNotes(familyId: string, from?: string, to?: string): Promise<NoteRow[]>;
  /** Inserts or replaces the note on each row's day. */
  upsertNotes(familyId: string, rows: NoteRow[]): Promise<void>;
  removeNotes(familyId: string, days: string[]): Promise<void>;
  /** Replaces all types, entries and notes of the family at once, and the finances too if
   *  given: all or nothing. */
  replaceContents(
    familyId: string,
    types: TypeInput[],
    entries: EntryRow[],
    notes: NoteRow[],
    finance?: FinanceContents,
  ): Promise<void>;
}

const CHUNK = 500;

function chunks<T>(list: T[], size = CHUNK): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

const yearOf = (day: string) => Number(day.slice(0, 4));

type FamilyRecord = typeof families.$inferSelect;

export function familyRow(f: FamilyRecord): FamilyRow {
  return {
    id: f.id,
    name: f.name,
    created_at: f.createdAt.toISOString(),
    updated_at: f.updatedAt.toISOString(),
  };
}

/** The types with their colors: each member's (and nobody's) types of a year shaded in order
 *  of position, then id (the order of `rows`). */
function withColors(
  rows: (typeof calEntryTypes.$inferSelect)[],
  colors: Map<string, string>,
): TypeRow[] {
  const seen = new Map<string, number>();
  return rows.map((t) => {
    // Someone no longer in the family (left without the cleanup) counts as nobody.
    const id = t.memberUserId ?? t.memberPersonId;
    const member_id = id && colors.has(id) ? id : null;
    const key = `${t.year}|${member_id ?? ""}`;
    const index = seen.get(key) ?? 0;
    seen.set(key, index + 1);
    const base = member_id ? memberColorHex(colors.get(member_id)) : NEUTRAL_COLOR;
    return {
      family_id: t.familyId,
      year: t.year,
      id: t.id,
      name: t.name,
      member_id,
      color: typeShade(base, index),
      role: isRole(t.role) ? t.role : "none",
      icon: t.icon ?? null,
      position: t.position,
      away: t.away,
    };
  });
}

/** The family's accounts and people by id, with their color keys. */
function memberColors(db: Pick<Db, "select">, familyId: string): Map<string, { color: string; account: boolean }> {
  const out = new Map<string, { color: string; account: boolean }>();
  for (const m of db
    .select({ id: familyMembers.userId, color: familyMembers.color })
    .from(familyMembers)
    .where(eq(familyMembers.familyId, familyId))
    .all()) {
    out.set(m.id, { color: m.color, account: true });
  }
  for (const p of db
    .select({ id: familyPeople.id, color: familyPeople.color })
    .from(familyPeople)
    .where(eq(familyPeople.familyId, familyId))
    .all()) {
    out.set(p.id, { color: p.color, account: false });
  }
  return out;
}

/** The member columns of a type: an account's or a person's id of the family; anything else
 *  is nobody (the routes refuse it before). */
function memberColumns(members: Map<string, { account: boolean }>, memberId: string | null) {
  const m = memberId ? members.get(memberId) : undefined;
  return {
    memberUserId: m?.account ? memberId : null,
    memberPersonId: m && !m.account ? memberId : null,
  };
}

/** The calendar store over Ohana's database. Calls run synchronously (better-sqlite3); they
 *  return promises to keep family-planner's interface. */
export class DrizzleCalendarStore implements CalendarStore {
  constructor(
    private db: Db,
    private now: () => Date = () => new Date(),
  ) {}

  async getFamily(id: string) {
    const f = this.db.select().from(families).where(eq(families.id, id)).get();
    return f ? familyRow(f) : null;
  }

  async updateFamily(id: string, patch: FamilyPatch) {
    this.db
      .update(families)
      .set({
        ...(patch.name !== undefined ? { name: patch.name } : {}),
        updatedAt: this.now(),
      })
      .where(eq(families.id, id))
      .run();
  }

  async listTypes(familyId: string) {
    const rows = this.db
      .select()
      .from(calEntryTypes)
      .where(eq(calEntryTypes.familyId, familyId))
      .orderBy(asc(calEntryTypes.year), asc(calEntryTypes.position), asc(calEntryTypes.id))
      .all();
    const colors = new Map([...memberColors(this.db, familyId)].map(([id, m]) => [id, m.color]));
    return withColors(rows, colors);
  }

  async upsertTypes(types: TypeInput[]) {
    // An upsert, never INSERT OR REPLACE: replacing would delete the type's entries (cascade).
    this.db.transaction((tx) => {
      const members = new Map<string, ReturnType<typeof memberColors>>();
      for (const t of types) {
        if (!members.has(t.family_id)) members.set(t.family_id, memberColors(tx, t.family_id));
        const set = {
          name: t.name,
          ...memberColumns(members.get(t.family_id)!, t.member_id),
          role: t.role,
          icon: t.icon ?? null,
          position: t.position,
          away: t.away ?? false,
        };
        tx.insert(calEntryTypes)
          .values({ familyId: t.family_id, year: t.year, id: t.id, ...set })
          .onConflictDoUpdate({ target: [calEntryTypes.familyId, calEntryTypes.year, calEntryTypes.id], set })
          .run();
      }
    });
  }

  async deleteType(familyId: string, year: number, typeId: string) {
    // cal_entries rows go away through the ON DELETE CASCADE foreign key.
    this.db
      .delete(calEntryTypes)
      .where(and(eq(calEntryTypes.familyId, familyId), eq(calEntryTypes.year, year), eq(calEntryTypes.id, typeId)))
      .run();
  }

  async listEntries(familyId: string, from?: string, to?: string) {
    return this.db
      .select({ day: calEntries.day, type_id: calEntries.typeId })
      .from(calEntries)
      .where(
        and(
          eq(calEntries.familyId, familyId),
          from ? gte(calEntries.day, from) : undefined,
          to ? lte(calEntries.day, to) : undefined,
        ),
      )
      .orderBy(asc(calEntries.day), asc(calEntries.typeId))
      .all();
  }

  async addEntries(familyId: string, rows: EntryRow[]) {
    this.db.transaction((tx) => {
      for (const part of chunks(rows)) {
        tx.insert(calEntries)
          .values(part.map((r) => ({ familyId, day: r.day, year: yearOf(r.day), typeId: r.type_id })))
          .onConflictDoNothing()
          .run();
      }
    });
  }

  async removeEntries(familyId: string, days: string[], typeIds?: string[]) {
    this.db.transaction((tx) => {
      for (const part of chunks(days)) {
        tx.delete(calEntries)
          .where(
            and(
              eq(calEntries.familyId, familyId),
              inArray(calEntries.day, part),
              typeIds ? inArray(calEntries.typeId, typeIds) : undefined,
            ),
          )
          .run();
      }
    });
  }

  async listNotes(familyId: string, from?: string, to?: string) {
    return this.db
      .select({ day: calNotes.day, icon: calNotes.icon, comment: calNotes.comment })
      .from(calNotes)
      .where(
        and(
          eq(calNotes.familyId, familyId),
          from ? gte(calNotes.day, from) : undefined,
          to ? lte(calNotes.day, to) : undefined,
        ),
      )
      .orderBy(asc(calNotes.day))
      .all();
  }

  async upsertNotes(familyId: string, rows: NoteRow[]) {
    // Setting a note replaces the existing one on that day.
    this.db.transaction((tx) => {
      for (const r of rows) {
        tx.insert(calNotes)
          .values({ familyId, day: r.day, icon: r.icon, comment: r.comment })
          .onConflictDoUpdate({
            target: [calNotes.familyId, calNotes.day],
            set: { icon: r.icon, comment: r.comment },
          })
          .run();
      }
    });
  }

  async removeNotes(familyId: string, days: string[]) {
    this.db.transaction((tx) => {
      for (const part of chunks(days)) {
        tx.delete(calNotes)
          .where(and(eq(calNotes.familyId, familyId), inArray(calNotes.day, part)))
          .run();
      }
    });
  }

  async replaceContents(
    familyId: string,
    types: TypeInput[],
    entries: EntryRow[],
    notes: NoteRow[],
    finance?: FinanceContents,
  ) {
    // One transaction, so a failed import leaves the family as it was.
    this.db.transaction((tx) => {
      tx.delete(calEntries).where(eq(calEntries.familyId, familyId)).run();
      tx.delete(calEntryTypes).where(eq(calEntryTypes.familyId, familyId)).run();
      tx.delete(calNotes).where(eq(calNotes.familyId, familyId)).run();
      const members = memberColors(tx, familyId);
      for (const part of chunks(types)) {
        tx.insert(calEntryTypes)
          .values(
            part.map((t) => ({
              familyId,
              year: t.year,
              id: t.id,
              name: t.name,
              ...memberColumns(members, t.member_id),
              role: t.role,
              icon: t.icon ?? null,
              position: t.position,
              away: t.away ?? false,
            })),
          )
          .run();
      }
      for (const part of chunks(entries)) {
        tx.insert(calEntries)
          .values(part.map((r) => ({ familyId, day: r.day, year: yearOf(r.day), typeId: r.type_id })))
          .onConflictDoNothing()
          .run();
      }
      for (const part of chunks(notes)) {
        tx.insert(calNotes)
          .values(part.map((n) => ({ familyId, day: n.day, icon: n.icon, comment: n.comment })))
          .run();
      }
      if (finance) replaceFinance(tx, familyId, finance);
      tx.update(families).set({ updatedAt: this.now() }).where(eq(families.id, familyId)).run();
    });
  }
}
