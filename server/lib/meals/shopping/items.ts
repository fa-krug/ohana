import { randomUUID } from "node:crypto";
import { and, eq, inArray } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { shoppingItemAdds, shoppingListItems, shoppingLists, planIterations, mealPlans } from "@/lib/db/schema";
import { Decimal, quantize2 } from "@/lib/meals/domain/decimal";

/** Returns the set of item ids (from `candidateIds`) that belong to `familyId`. */
function ownedItemIds(db: Db, familyId: string, candidateIds: string[]): Set<string> {
  if (candidateIds.length === 0) return new Set();
  const rows = db
    .select({ id: shoppingListItems.id })
    .from(shoppingListItems)
    .innerJoin(shoppingLists, eq(shoppingListItems.shoppingListId, shoppingLists.id))
    .innerJoin(planIterations, eq(shoppingLists.iterationId, planIterations.id))
    .innerJoin(mealPlans, eq(planIterations.mealPlanId, mealPlans.id))
    .where(and(inArray(shoppingListItems.id, candidateIds), eq(mealPlans.familyId, familyId)))
    .all();
  return new Set(rows.map((r) => r.id));
}

export function toggleShoppingItem(db: Db, familyId: string, itemId: string): boolean {
  if (!ownedItemIds(db, familyId, [itemId]).has(itemId)) {
    throw new AuthError(404, "Item not found");
  }
  const current = db
    .select({ isChecked: shoppingListItems.isChecked })
    .from(shoppingListItems)
    .where(eq(shoppingListItems.id, itemId))
    .get();
  if (current === undefined) {
    throw new AuthError(404, "Item not found");
  }
  const next = !current.isChecked;
  db.update(shoppingListItems).set({ isChecked: next }).where(eq(shoppingListItems.id, itemId)).run();
  return next;
}

export function setShoppingItemsChecked(
  db: Db,
  familyId: string,
  itemIds: string[],
  isChecked: boolean,
): number {
  const owned = [...ownedItemIds(db, familyId, itemIds)];
  if (owned.length === 0) return 0;
  db.update(shoppingListItems)
    .set({ isChecked })
    .where(inArray(shoppingListItems.id, owned))
    .run();
  return owned.length;
}

/** The list, if it belongs to the family (via its plan); else a 404. */
function ownedList(db: Db, familyId: string, listId: string): void {
  const row = db
    .select({ id: shoppingLists.id })
    .from(shoppingLists)
    .innerJoin(planIterations, eq(shoppingLists.iterationId, planIterations.id))
    .innerJoin(mealPlans, eq(planIterations.mealPlanId, mealPlans.id))
    .where(and(eq(shoppingLists.id, listId), eq(mealPlans.familyId, familyId)))
    .get();
  if (!row) throw new AuthError(404, "Shopping list not found");
}

type AddResult = { id: string; merged: boolean; previousQuantity: string | null };

/**
 * An add with this `clientId` already applied to the list: its result (a retry whose answer was
 * lost), else null.
 */
export function earlierShoppingAdd(db: Db, listId: string, clientId: string): AddResult | null {
  const row = db
    .select()
    .from(shoppingItemAdds)
    .where(and(eq(shoppingItemAdds.shoppingListId, listId), eq(shoppingItemAdds.clientId, clientId)))
    .get();
  return row ? { id: row.itemId, merged: row.merged, previousQuantity: row.previousQuantity } : null;
}

/**
 * Adds an item to one of the family's shopping lists. An unticked item of the same ingredient
 * and unit gets the quantity added instead (`merged`, with the quantity it had before). With a
 * `clientId` (the app's, for its offline queue) an add is applied once: sent again, it returns
 * the earlier result.
 */
export function addShoppingItem(
  db: Db,
  familyId: string,
  listId: string,
  input: { ingredientId: number; unitId: number; quantity: string; clientId?: string },
): AddResult {
  ownedList(db, familyId, listId);
  const { clientId } = input;
  if (clientId === undefined) return applyAdd(db, listId, input);
  return db.transaction(() => {
    const earlier = earlierShoppingAdd(db, listId, clientId);
    if (earlier) return earlier;
    const result = applyAdd(db, listId, input);
    db.insert(shoppingItemAdds)
      .values({ shoppingListId: listId, clientId, itemId: result.id, merged: result.merged, previousQuantity: result.previousQuantity })
      .run();
    return result;
  });
}

function applyAdd(db: Db, listId: string, input: { ingredientId: number; unitId: number; quantity: string }): AddResult {
  let quantity: Decimal;
  try {
    quantity = new Decimal(input.quantity);
  } catch {
    throw new AuthError(422, "The quantity must be a number");
  }
  if (!quantity.isFinite() || quantity.lte(0)) throw new AuthError(422, "The quantity must be more than 0");
  const same = db
    .select()
    .from(shoppingListItems)
    .where(
      and(
        eq(shoppingListItems.shoppingListId, listId),
        eq(shoppingListItems.ingredientId, input.ingredientId),
        eq(shoppingListItems.unitId, input.unitId),
        eq(shoppingListItems.isChecked, false),
      ),
    )
    .get();
  if (same) {
    const sum = quantize2(new Decimal(same.quantity).plus(quantity)).toString();
    db.update(shoppingListItems).set({ quantity: sum }).where(eq(shoppingListItems.id, same.id)).run();
    return { id: same.id, merged: true, previousQuantity: same.quantity };
  }
  const id = randomUUID();
  db.insert(shoppingListItems)
    .values({
      id,
      shoppingListId: listId,
      ingredientId: input.ingredientId,
      unitId: input.unitId,
      quantity: quantize2(quantity).toString(),
      isChecked: false,
    })
    .run();
  return { id, merged: false, previousQuantity: null };
}

/** Sets an item's quantity (the undo of a merged add). */
export function setShoppingItemQuantity(db: Db, familyId: string, itemId: string, quantity: string): void {
  if (!ownedItemIds(db, familyId, [itemId]).has(itemId)) throw new AuthError(404, "Item not found");
  let q: Decimal;
  try {
    q = new Decimal(quantity);
  } catch {
    throw new AuthError(422, "The quantity must be a number");
  }
  if (!q.isFinite() || q.lte(0)) throw new AuthError(422, "The quantity must be more than 0");
  db.update(shoppingListItems).set({ quantity: q.toString() }).where(eq(shoppingListItems.id, itemId)).run();
}

/** Deletes one of the family's shopping-list items. */
export function deleteShoppingItem(db: Db, familyId: string, itemId: string): void {
  if (!ownedItemIds(db, familyId, [itemId]).has(itemId)) throw new AuthError(404, "Item not found");
  db.delete(shoppingListItems).where(eq(shoppingListItems.id, itemId)).run();
}
