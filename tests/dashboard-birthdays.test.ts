// The family overview lists the birthdays of the next 30 days (today included), accounts and
// people without one alike.

import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { familyMembers } from "@/lib/db/schema";
import { familyDashboard } from "@/lib/families/dashboard";
import { addPerson } from "@/lib/families/people";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

describe("birthdays on the overview", () => {
  it("shows the next 30 days' birthdays by day, with the age they turn", async () => {
    const db = createTestDb();
    const editor = makeUser(db, { name: "Anna" });
    const f = makeFamily(db, editor.id);
    db.update(familyMembers).set({ birthday: "1990-11-01" }).where(eq(familyMembers.userId, editor.id)).run();
    const add = (name: string, birthday: string | null) => addPerson(db, { id: editor.id }, f.id, { name, birthday }, NOW);
    add("Mia", "2018-11-15");
    add("Leo", "2020-11-30"); // 29 days on: still in
    add("Ben", "2021-12-01"); // 30 days on: out
    add("Opa", "1950-10-31"); // yesterday: out
    add("Ida", null);

    const d = await familyDashboard(db, f.id, "2026-11-01");
    expect(d.birthdays).toEqual([
      { day: "2026-11-01", name: "Anna", age: 36 },
      { day: "2026-11-15", name: "Mia", age: 8 },
      { day: "2026-11-30", name: "Leo", age: 6 },
    ]);
  });

  it("is empty when nobody has a birthday coming up", async () => {
    const db = createTestDb();
    const editor = makeUser(db);
    const f = makeFamily(db, editor.id);
    expect((await familyDashboard(db, f.id, "2026-11-01")).birthdays).toEqual([]);
  });
});
