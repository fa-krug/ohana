// Phase 7, Calendar → Meals: calendar types marked "away" make the meal plan leave their days
// out (no cooking, no leftovers, no fallback), and the flag travels through the type API, the
// export file and the import.

import { and, eq } from "drizzle-orm";
import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import { calEntries, calEntryTypes, ingredients, mealPlanEntries, recipeIngredients, recipes, units } from "@/lib/db/schema";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { handleFamily } from "@/lib/calendar/family-routes";
import { handleCalendar } from "@/lib/calendar/vacation";
import { assignSchedule } from "@/lib/meals/domain/meal-plan/schedule";
import { mulberry32 } from "@/lib/meals/domain/rng";
import { awayDays } from "@/lib/meals/meal-plan/away";
import { setupMealPlan } from "@/lib/meals/meal-plan/setup";
import { renewIteration } from "@/lib/meals/meal-plan/iterations";
import { shoppingNeeds } from "@/lib/meals/shopping/needs";
import { familyDashboard } from "@/lib/families/dashboard";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

describe("assignSchedule with skipped days", () => {
  it("plans nothing on skipped days and keeps leftovers off them", () => {
    const skip = new Set(["2026-06-02", "2026-06-03", "2026-06-04"]);
    for (let seed = 1; seed < 30; seed++) {
      const planned = assignSchedule({
        recipes: [
          { id: "a", leftoverDays: 2 },
          { id: "b", leftoverDays: 1 },
        ],
        fallbackRecipes: [{ id: "c", leftoverDays: 0 }],
        startDate: "2026-06-01",
        days: 7,
        servings: 2,
        defaultLeftoverDays: 1,
        rng: mulberry32(seed),
        skipDates: skip,
      });
      const days = planned.map((p) => p.date);
      expect(days.some((d) => skip.has(d))).toBe(false);
      // Every day at home gets exactly one meal.
      expect([...days].sort()).toEqual(["2026-06-01", "2026-06-05", "2026-06-06", "2026-06-07"]);
      // Leftovers still come 2+ calendar days after their cooking day.
      for (const p of planned.filter((x) => x.isLeftover)) {
        expect(Date.parse(p.date) - Date.parse(p.sourceDate!)).toBeGreaterThanOrEqual(2 * 86_400_000);
      }
    }
  });
});

let db: Db;
let familyId: string;
let editorId: string;
const now = new Date("2026-06-01T08:00:00Z"); // a Monday

function seedRecipes() {
  db.insert(units).values({ id: 1, nameEn: "gram", nameDe: "Gramm", abbreviation: "g", conversionFactor: "1" }).run();
  db.insert(ingredients).values({ id: 1, nameEn: "Tomato", nameDe: "Tomate", category: "PRODUCE" }).run();
  for (const id of ["k1", "k2", "k3", "k4", "t1", "t2"]) {
    db.insert(recipes)
      .values({ id, familyId, title: id, description: "", listType: id.startsWith("k") ? "KNOWN" : "TO_TRY", defaultServings: 2, createdAt: now, updatedAt: now })
      .run();
    db.insert(recipeIngredients).values({ recipeId: id, ingredientId: 1, quantity: "100", unitId: 1, order: 0 }).run();
  }
}

function addType(id: string, away: boolean, role = "none") {
  db.insert(calEntryTypes).values({ familyId, year: 2026, id, name: id === "trip" ? "Trip" : id, color: "#123456", role, position: 9, away }).run();
}
function mark(typeId: string, days: string[]) {
  for (const day of days) db.insert(calEntries).values({ familyId, day, year: 2026, typeId }).run();
}

beforeEach(() => {
  db = createTestDb();
  editorId = makeUser(db).id;
  familyId = makeFamily(db, editorId).id;
  seedRecipes();
});

const input = { iterationWeeks: 1, shoppingDays: [1], servings: 2, knownRatio: 0.7, defaultLeftoverDays: 1, excludedTagIds: [] };

describe("meal plan and away days", () => {
  it("finds the away days with their types' names", () => {
    addType("trip", true);
    addType("course", false);
    mark("trip", ["2026-06-03", "2026-06-04"]);
    mark("course", ["2026-06-05"]);
    expect([...awayDays(db, familyId, "2026-06-01", "2026-06-07")]).toEqual([
      ["2026-06-03", ["Trip"]],
      ["2026-06-04", ["Trip"]],
    ]);
  });

  it("plans no meals on away days, on setup and on renew", () => {
    addType("trip", true);
    addType("course", false); // not away: still planned
    mark("trip", ["2026-06-03", "2026-06-04", "2026-06-05"]);
    mark("course", ["2026-06-02"]);
    const { iterationId } = setupMealPlan(db, familyId, input, now, mulberry32(7));
    const days = () =>
      db
        .select({ date: mealPlanEntries.date })
        .from(mealPlanEntries)
        .where(eq(mealPlanEntries.iterationId, iterationId))
        .all()
        .map((e) => e.date)
        .sort();
    expect(days()).toEqual(["2026-06-01", "2026-06-02", "2026-06-06", "2026-06-07"]);
    // What the plan needs is only what the days at home need.
    const needed = shoppingNeeds(db, familyId, { from: "2026-01-01", locale: "en" });
    expect(needed.length).toBeGreaterThan(0);

    // A trip planned later is respected when the plan is renewed.
    mark("trip", ["2026-06-07"]);
    renewIteration(db, familyId, iterationId, mulberry32(3));
    expect(days()).toEqual(["2026-06-01", "2026-06-02", "2026-06-06"]);
  });

  it("ignores the away flag of other families and of other years' types", () => {
    const other = makeFamily(db, makeUser(db).id);
    db.insert(calEntryTypes).values({ familyId: other.id, year: 2026, id: "trip", name: "Trip", color: "#123456", away: true }).run();
    db.insert(calEntries).values({ familyId: other.id, day: "2026-06-03", year: 2026, typeId: "trip" }).run();
    const { iterationId } = setupMealPlan(db, familyId, input, now, mulberry32(1));
    expect(db.select().from(mealPlanEntries).where(eq(mealPlanEntries.iterationId, iterationId)).all()).toHaveLength(7);
  });

  it("shows today as away on the overview", async () => {
    addType("trip", true);
    mark("trip", ["2026-06-03"]);
    expect((await familyDashboard(db, familyId, "2026-06-03")).awayToday).toEqual(["Trip"]);
    expect((await familyDashboard(db, familyId, "2026-06-02")).awayToday).toEqual([]);
  });
});

describe("the away flag in the calendar API", () => {
  function call() {
    const handler = createFamilyApi([handleFamily, handleCalendar], { db, appUrl: "http://ohana.test", now: () => NOW });
    const token = createToken(db, { userId: editorId, kind: "api" }, NOW).token;
    return async (method: string, path: string, body?: unknown) => {
      const res = await handler(
        new Request(`http://ohana.test/api/v1${path}`, {
          method,
          headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
          body: body === undefined ? undefined : JSON.stringify(body),
        }),
      );
      return { status: res.status, data: await res.json() };
    };
  }

  it("creates, patches, copies, exports and imports it", async () => {
    const api = call();
    const created = await api("POST", `/families/${familyId}/types?year=2026`, { name: "Away", color: "#112233", away: true });
    expect(created.data.away).toBe(true);
    expect((await api("POST", `/families/${familyId}/types?year=2026`, { name: "Bad", color: "#112233", away: "yes" })).status).toBe(400);
    const patched = await api("PATCH", `/families/${familyId}/types/vacation?year=2026`, { away: true });
    expect(patched.data).toMatchObject({ id: "vacation", away: true, role: "covers" });
    const listed = await api("GET", `/families/${familyId}/types?year=2026`);
    expect(listed.data.map((t: any) => [t.id, t.away])).toEqual([
      ["holiday", false],
      ["vacation", true],
      ["sick", false],
      ["away", true],
    ]);
    // Renaming keeps it (an upsert of the other fields).
    await api("PATCH", `/families/${familyId}/types/vacation?year=2026`, { name: "Urlaub" });
    expect(
      db.select().from(calEntryTypes).where(and(eq(calEntryTypes.familyId, familyId), eq(calEntryTypes.id, "vacation"))).get()!.away,
    ).toBe(true);

    await api("POST", `/families/${familyId}/types/copy`, { from: 2026, to: 2027 });
    expect((await api("GET", `/families/${familyId}/types?year=2027`)).data.find((t: any) => t.id === "away").away).toBe(true);

    const file = (await api("GET", `/families/${familyId}/export`)).data;
    expect(file.types.find((t: any) => t.id === "away" && t.year === 2026).away).toBe(true);
    // A family-planner file has no "away": false.
    const imported = await api("POST", `/families/${familyId}/import?year=2026`, {
      ...file,
      types: file.types.map((t: any) => (t.id === "vacation" ? { ...t, away: undefined } : t)),
    });
    expect(imported.status).toBe(200);
    expect(imported.data.types.map((t: any) => [t.id, t.away])).toEqual([
      ["holiday", false],
      ["vacation", false],
      ["sick", false],
      ["away", true],
    ]);
  });
});
