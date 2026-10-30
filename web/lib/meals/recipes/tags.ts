import { randomUUID } from "node:crypto";
import { and, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { mealTags } from "@/lib/db/schema";
import { DEFAULT_TAGS } from "./tag-defaults";
import { AuthError } from "@/lib/auth/errors";

/** Seed default tags for a household. Idempotent — skips existing (category, nameEn) pairs. */
export function seedDefaultTags(db: Db, familyId: string): void {
  const existing = new Set(
    db
      .select({ category: mealTags.category, nameEn: mealTags.nameEn })
      .from(mealTags)
      .where(eq(mealTags.familyId, familyId))
      .all()
      .map((t) => `${t.category}::${t.nameEn}`),
  );

  const toCreate: (typeof mealTags.$inferInsert)[] = [];
  for (const [category, list] of Object.entries(DEFAULT_TAGS)) {
    for (const [nameEn, nameDe] of list) {
      if (!existing.has(`${category}::${nameEn}`)) {
        toCreate.push({ id: randomUUID(), familyId, category, nameEn, nameDe, isDefault: true });
      }
    }
  }
  if (toCreate.length > 0) db.insert(mealTags).values(toCreate).run();
}

const VALID_CATEGORIES = new Set(["DIETARY", "PROTEIN", "CUISINE", "MEAL_TYPE"]);

function ownedTag(db: Db, familyId: string, tagId: string) {
  const row = db
    .select({ id: mealTags.id })
    .from(mealTags)
    .where(and(eq(mealTags.id, tagId), eq(mealTags.familyId, familyId)))
    .get();
  if (!row) throw new AuthError(404, "Tag not found");
  return row;
}

export function createTag(
  db: Db,
  familyId: string,
  input: { category: string; nameEn: string; nameDe: string },
): { id: string } {
  if (!VALID_CATEGORIES.has(input.category)) {
    throw new AuthError(422, `Invalid category: ${input.category}`);
  }
  if (!input.nameEn.trim() || !input.nameDe.trim()) {
    throw new AuthError(422, "Tag names are required");
  }
  const id = randomUUID();
  db.insert(mealTags)
    .values({ id, familyId, category: input.category, nameEn: input.nameEn, nameDe: input.nameDe, isDefault: false })
    .run();
  return { id };
}

export function updateTag(
  db: Db,
  familyId: string,
  tagId: string,
  input: { nameEn: string; nameDe: string },
): void {
  ownedTag(db, familyId, tagId);
  if (!input.nameEn.trim() || !input.nameDe.trim()) {
    throw new AuthError(422, "Tag names are required");
  }
  db.update(mealTags).set({ nameEn: input.nameEn, nameDe: input.nameDe }).where(eq(mealTags.id, tagId)).run();
}

export function deleteTag(db: Db, familyId: string, tagId: string): void {
  ownedTag(db, familyId, tagId);
  db.delete(mealTags).where(eq(mealTags.id, tagId)).run();
}

export function resetTags(db: Db, familyId: string): void {
  db.transaction((tx) => {
    tx.delete(mealTags).where(eq(mealTags.familyId, familyId)).run();
    seedDefaultTags(tx as unknown as Db, familyId);
  });
}
