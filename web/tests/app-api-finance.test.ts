// The finance routes of the native app (lib/finance/app-routes.ts): the shopping-list links of
// the groceries transactions, which the web page gets server-side.

import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import { familyMembers, shoppingLists } from "@/lib/db/schema";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { handleFinance } from "@/lib/finance/finance";
import { handleFinanceApp } from "@/lib/finance/app-routes";
import { setupMealPlan } from "@/lib/meals/meal-plan/setup";
import { mulberry32 } from "@/lib/meals/domain/rng";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

let db: Db;
let familyId: string;
let editorId: string;

beforeEach(() => {
  db = createTestDb();
  editorId = makeUser(db, { email: "editor@test" }).id;
  familyId = makeFamily(db, editorId).id; // with the default categories (Groceries, …)
});

function caller(userId: string) {
  const handler = createFamilyApi([handleFinanceApp, handleFinance], { db, appUrl: "http://ohana.test", now: () => NOW });
  const token = createToken(db, { userId, kind: "api" }, NOW).token;
  return async (method: string, path: string, id = familyId) => {
    const res = await handler(
      new Request(`http://ohana.test/api/v1/families/${id}${path}`, {
        method,
        headers: { authorization: `Bearer ${token}` },
      }),
    );
    return { status: res.status, data: await res.json() };
  };
}

describe("GET /finance/shopping-links", () => {
  it("lists the groceries categories and the shopping days", async () => {
    const call = caller(editorId);
    expect((await call("GET", "/finance/shopping-links")).data).toEqual({ categoryIds: ["groceries"], lists: [] });

    const now = new Date("2026-06-01T08:00:00Z"); // a Monday
    setupMealPlan(
      db,
      familyId,
      { iterationWeeks: 1, shoppingDays: [0, 3], servings: 2, knownRatio: 1, defaultLeftoverDays: 1, excludedTagIds: [] },
      now,
      mulberry32(1),
    );
    const res = await call("GET", "/finance/shopping-links");
    expect(res.status).toBe(200);
    const ids = new Map(db.select().from(shoppingLists).all().map((l) => [l.shoppingDate, l.id]));
    expect(res.data.lists).toEqual([
      { id: ids.get("2026-06-01"), date: "2026-06-01" },
      { id: ids.get("2026-06-04"), date: "2026-06-04" },
    ]);
  });

  it("is for members (viewers too) only", async () => {
    const viewer = makeUser(db, { email: "viewer@test" });
    db.insert(familyMembers).values({ familyId, userId: viewer.id, role: "viewer", joinedAt: NOW }).run();
    expect((await caller(viewer.id)("GET", "/finance/shopping-links")).status).toBe(200);
    const stranger = makeUser(db, { email: "stranger@test" });
    expect((await caller(stranger.id)("GET", "/finance/shopping-links")).status).toBe(404);
  });

  it("leaves the other finance routes alone", async () => {
    const call = caller(editorId);
    expect((await call("GET", "/finance")).data.currency).toBe("EUR");
    expect((await call("POST", "/finance/shopping-links")).status).toBe(404);
  });
});
