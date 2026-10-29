// Storage of the calendar: family-planner's `Store` interface (the calendar part of
// _shared/store.ts) over Drizzle/SQLite, so vacation.ts and ics.ts work on it as they did on
// Supabase. Rows keep family-planner's snake_case shapes.

import { and, asc, eq, gte, inArray, lte, or } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { calEntries, calEntryTypes, calNotes, families } from "@/lib/db/schema";

export type Role = "none" | "needs_cover" | "covers" | "day_off";
export const ROLES: Role[] = ["none", "needs_cover", "covers", "day_off"];

export function isRole(v: unknown): v is Role {
  return ROLES.includes(v as Role);
}

export interface FamilyRow {
  id: string;
  /** Calendar feed token: only calendar.ics, without signing in. */
  feed_id: string;
  /** The view token of a planner from before families: its calendar feed. */
  legacy_id: string | null;
  name: string;
  created_at: string;
  updated_at: string;
}

export type FamilyPatch = Partial<Pick<FamilyRow, "name" | "feed_id" | "legacy_id">>;

/** An entry type belongs to one year; each year of a family has its own set. */
export interface TypeRow {
  family_id: string;
  year: number;
  id: string; // unique within the family's year
  name: string;
  color: string;
  role: Role;
  position: number;
}

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
  /** The family whose feed id or legacy id this is. */
  findFeed(token: string): Promise<FamilyRow | null>;
  getFamily(id: string): Promise<FamilyRow | null>;
  updateFamily(id: string, patch: FamilyPatch): Promise<void>;

  /** Types of all years, ordered by year and position. */
  listTypes(familyId: string): Promise<TypeRow[]>;
  upsertTypes(types: TypeRow[]): Promise<void>;
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
  /** Replaces all types, entries and notes of the family at once: all or nothing. */
  replaceContents(familyId: string, types: TypeRow[], entries: EntryRow[], notes: NoteRow[]): Promise<void>;
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
    feed_id: f.feedId,
    legacy_id: f.legacyId,
    name: f.name,
    created_at: f.createdAt.toISOString(),
    updated_at: f.updatedAt.toISOString(),
  };
}

function typeRow(t: typeof calEntryTypes.$inferSelect): TypeRow {
  return {
    family_id: t.familyId,
    year: t.year,
    id: t.id,
    name: t.name,
    color: t.color,
    role: isRole(t.role) ? t.role : "none",
    position: t.position,
  };
}

/** The calendar store over Ohana's database. Calls run synchronously (better-sqlite3); they
 *  return promises to keep family-planner's interface. */
export class DrizzleCalendarStore implements CalendarStore {
  constructor(
    private db: Db,
    private now: () => Date = () => new Date(),
  ) {}

  async findFeed(token: string) {
    const f = this.db
      .select()
      .from(families)
      .where(or(eq(families.feedId, token), eq(families.legacyId, token)))
      .get();
    return f ? familyRow(f) : null;
  }

  async getFamily(id: string) {
    const f = this.db.select().from(families).where(eq(families.id, id)).get();
    return f ? familyRow(f) : null;
  }

  async updateFamily(id: string, patch: FamilyPatch) {
    this.db
      .update(families)
      .set({
        ...(patch.name !== undefined ? { name: patch.name } : {}),
        ...(patch.feed_id !== undefined ? { feedId: patch.feed_id } : {}),
        ...(patch.legacy_id !== undefined ? { legacyId: patch.legacy_id } : {}),
        updatedAt: this.now(),
      })
      .where(eq(families.id, id))
      .run();
  }

  async listTypes(familyId: string) {
    return this.db
      .select()
      .from(calEntryTypes)
      .where(eq(calEntryTypes.familyId, familyId))
      .orderBy(asc(calEntryTypes.year), asc(calEntryTypes.position), asc(calEntryTypes.id))
      .all()
      .map(typeRow);
  }

  async upsertTypes(types: TypeRow[]) {
    // An upsert, never INSERT OR REPLACE: replacing would delete the type's entries (cascade).
    this.db.transaction((tx) => {
      for (const t of types) {
        const values = {
          familyId: t.family_id,
          year: t.year,
          id: t.id,
          name: t.name,
          color: t.color,
          role: t.role,
          position: t.position,
        };
        tx.insert(calEntryTypes)
          .values(values)
          .onConflictDoUpdate({
            target: [calEntryTypes.familyId, calEntryTypes.year, calEntryTypes.id],
            set: { name: t.name, color: t.color, role: t.role, position: t.position },
          })
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

  async replaceContents(familyId: string, types: TypeRow[], entries: EntryRow[], notes: NoteRow[]) {
    // One transaction, so a failed import leaves the family as it was.
    this.db.transaction((tx) => {
      tx.delete(calEntries).where(eq(calEntries.familyId, familyId)).run();
      tx.delete(calEntryTypes).where(eq(calEntryTypes.familyId, familyId)).run();
      tx.delete(calNotes).where(eq(calNotes.familyId, familyId)).run();
      for (const part of chunks(types)) {
        tx.insert(calEntryTypes)
          .values(
            part.map((t) => ({
              familyId,
              year: t.year,
              id: t.id,
              name: t.name,
              color: t.color,
              role: t.role,
              position: t.position,
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
      tx.update(families).set({ updatedAt: this.now() }).where(eq(families.id, familyId)).run();
    });
  }
}
