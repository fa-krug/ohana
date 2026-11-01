// Members' birthdays in the calendar: GET /families/{id} by day, and the feed with birthdays=1.

import { describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { handleFamily } from "@/lib/calendar/family-routes";
import { handleCalendar } from "@/lib/calendar/vacation";
import { birthdaysIn } from "@/lib/families/birthdays";
import { setMemberBirthday } from "@/lib/families/members";
import { addPerson } from "@/lib/families/people";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

describe("birthdaysIn", () => {
  const people = [
    { name: "Mia", birthday: "2019-05-03" },
    { name: "Leap", birthday: "2020-02-29" },
    { name: "Nobody", birthday: null },
    { name: "Baby", birthday: "2026-07-01" },
  ];

  it("lists the range's birthdays with the age they turn, by day", () => {
    expect(birthdaysIn(people, "2026-01-01", "2026-12-31")).toEqual([
      { day: "2026-02-28", name: "Leap", age: 6 },
      { day: "2026-05-03", name: "Mia", age: 7 },
    ]);
    expect(birthdaysIn(people, "2028-02-01", "2028-03-01")).toEqual([{ day: "2028-02-29", name: "Leap", age: 8 }]);
    expect(birthdaysIn(people, "2027-06-30", "2027-07-01")).toEqual([{ day: "2027-07-01", name: "Baby", age: 1 }]);
  });
});

function call(db: Db, token: string | null) {
  const handler = createFamilyApi([handleFamily, handleCalendar], { db, appUrl: "http://ohana.test", now: () => NOW });
  return async (path: string) => {
    const res = await handler(
      new Request("http://ohana.test/api/v1" + path, { headers: token ? { authorization: `Bearer ${token}` } : {} }),
    );
    const text = await res.text();
    return { status: res.status, text, data: res.headers.get("content-type")?.includes("json") ? JSON.parse(text) : null };
  };
}

describe("the calendar", () => {
  it("shows the members' birthdays of the year", async () => {
    const db = createTestDb();
    const editor = makeUser(db, { name: "Sascha" });
    const f = makeFamily(db, editor.id);
    setMemberBirthday(db, { id: editor.id }, f.id, editor.id, "1985-06-15", NOW);
    addPerson(db, { id: editor.id }, f.id, { name: "Mia", birthday: "2020-02-29" }, NOW);
    const token = createToken(db, { userId: editor.id, kind: "api" }, NOW).token;

    const state = (await call(db, token)(`/families/${f.id}?year=2026`)).data;
    expect(state.birthdays).toEqual({
      "2026-02-28": [{ name: "Mia", age: 6 }],
      "2026-06-15": [{ name: "Sascha", age: 41 }],
    });

  });
});
