// What a plan iteration holds (its meals), so a change the assistant made to the plan can be
// undone: the snapshot taken before goes into the undo step, and restoreIterations puts it back
// (POST /families/{id}/meals/plan/restore).

import { and, eq, inArray } from "drizzle-orm";
import { z } from "zod";
import type { Db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { mealPlanEntries, mealPlans, planIterations, recipes } from "@/lib/db/schema";

const entrySchema = z.object({
  id: z.string().min(1).max(64),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  mealType: z.string().max(20),
  recipeId: z.string().min(1).max(64),
  servings: z.number().int().min(1).max(100),
  isLeftover: z.boolean(),
  sourceEntryId: z.string().max(64).nullable(),
  isLocked: z.boolean(),
});

export const iterationSnapshotSchema = z.object({
  id: z.string().min(1).max(64),
  startDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  endDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  status: z.enum(["ACTIVE", "ARCHIVED"]),
  entries: z.array(entrySchema).max(200),
});

export type IterationSnapshot = z.infer<typeof iterationSnapshotSchema>;

export const restoreSchema = z.object({
  /** Iterations put back as they were. */
  restore: z.array(iterationSnapshotSchema).max(10).default([]),
  /** Iterations the change added: deleted. */
  remove: z.array(z.string().min(1).max(64)).max(10).default([]),
});

function ownedIteration(db: Db, familyId: string, iterationId: string) {
  return db
    .select({ id: planIterations.id, planId: planIterations.mealPlanId, createdAt: planIterations.createdAt })
    .from(planIterations)
    .innerJoin(mealPlans, eq(planIterations.mealPlanId, mealPlans.id))
    .where(and(eq(planIterations.id, iterationId), eq(mealPlans.familyId, familyId)))
    .get();
}

/** The iteration with its meals; 404 unless it is the family's. */
export function snapshotIteration(db: Db, familyId: string, iterationId: string): IterationSnapshot {
  const it = db
    .select()
    .from(planIterations)
    .innerJoin(mealPlans, eq(planIterations.mealPlanId, mealPlans.id))
    .where(and(eq(planIterations.id, iterationId), eq(mealPlans.familyId, familyId)))
    .get();
  if (!it) throw new AuthError(404, "Iteration not found");
  const entries = db
    .select()
    .from(mealPlanEntries)
    .where(eq(mealPlanEntries.iterationId, iterationId))
    .all()
    .sort((a, b) => a.date.localeCompare(b.date));
  return {
    id: it.plan_iterations.id,
    startDate: it.plan_iterations.startDate,
    endDate: it.plan_iterations.endDate,
    status: it.plan_iterations.status === "ARCHIVED" ? "ARCHIVED" : "ACTIVE",
    entries: entries.map((e) => ({
      id: e.id,
      date: e.date,
      mealType: e.mealType,
      recipeId: e.recipeId,
      servings: e.servings,
      isLeftover: e.isLeftover,
      sourceEntryId: e.sourceEntryId,
      isLocked: e.isLocked,
    })),
  };
}

/** Puts iterations back as their snapshots say and deletes the ones a change added (all of the
 *  family's, or nothing). Meals of recipes deleted since are left out. */
export function restoreIterations(db: Db, familyId: string, raw: unknown, now: Date): void {
  const input = restoreSchema.parse(raw);
  for (const id of [...input.remove, ...input.restore.map((s) => s.id)]) {
    if (!ownedIteration(db, familyId, id)) throw new AuthError(404, "Iteration not found");
  }
  const recipeIds = [...new Set(input.restore.flatMap((s) => s.entries.map((e) => e.recipeId)))];
  const known = new Set(
    recipeIds.length
      ? db
          .select({ id: recipes.id })
          .from(recipes)
          .where(and(eq(recipes.familyId, familyId), inArray(recipes.id, recipeIds)))
          .all()
          .map((r) => r.id)
      : [],
  );
  db.transaction((tx) => {
    for (const id of input.remove) tx.delete(planIterations).where(eq(planIterations.id, id)).run();
    for (const snap of input.restore) {
      tx.update(planIterations)
        .set({ startDate: snap.startDate, endDate: snap.endDate, status: snap.status })
        .where(eq(planIterations.id, snap.id))
        .run();
      tx.delete(mealPlanEntries).where(eq(mealPlanEntries.iterationId, snap.id)).run();
      const entries = snap.entries.filter((e) => known.has(e.recipeId));
      const ids = new Set(entries.map((e) => e.id));
      if (entries.length) {
        tx.insert(mealPlanEntries)
          .values(entries.map((e) => ({ ...e, iterationId: snap.id, sourceEntryId: null })))
          .run();
        for (const e of entries) {
          if (e.sourceEntryId && ids.has(e.sourceEntryId)) {
            tx.update(mealPlanEntries).set({ sourceEntryId: e.sourceEntryId }).where(eq(mealPlanEntries.id, e.id)).run();
          }
        }
      }
    }
  });
}
