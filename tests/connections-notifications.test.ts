// Phase 7, notifications everywhere: per-family event preferences, the daily coverage alert
// (sent once per new set of uncovered days), the shopping reminder, and appointment
// notifications that the family can turn off.

import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import * as schema from "@/lib/db/schema";
import { createChannel } from "@/lib/notifications/channels";
import type { Channel, Message } from "@/lib/notifications";
import { getPref, getPrefs, setPref } from "@/lib/notifications/prefs";
import { checkCoverage, remindShopping, uncoveredDays } from "@/lib/notifications/daily";
import { notifyRun } from "@/lib/appointments/notify";
import { setupMealPlan } from "@/lib/meals/meal-plan/setup";
import { mulberry32 } from "@/lib/meals/domain/rng";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";
import { makeResult, makeRun, makeSearch } from "@/lib/test/appointments";

let db: Db;
let familyId: string;
let editorId: string;
let viewerId: string;
let phone: string;
let mail: string;
const sent: { channel: Channel; msg: Message }[] = [];
const ok = async (channel: Channel, msg: Message) => void sent.push({ channel, msg });
const failing = async () => {
  throw new Error("down");
};

const channel = (name: string) =>
  createChannel(
    db,
    { id: editorId },
    familyId,
    { name, provider: "PUSHBULLET", token: "tok", target: "", smtpHost: "", smtpPort: 465, smtpUsername: "", smtpFrom: "", enabled: true },
    NOW,
  ).id;

beforeEach(() => {
  db = createTestDb();
  editorId = makeUser(db).id;
  viewerId = makeUser(db).id;
  familyId = makeFamily(db, editorId, [{ userId: viewerId, role: "viewer" }]).id;
  phone = channel("Phone");
  mail = channel("Mail");
  sent.length = 0;
});

describe("preferences", () => {
  it("have defaults and are set by editors, with the family's channels only", () => {
    expect(getPrefs(db, familyId)).toEqual([
      { event: "appointment_found", enabled: true, channelIds: null },
      { event: "coverage_gap", enabled: true, channelIds: null },
      { event: "shopping_reminder", enabled: false, channelIds: null },
      { event: "assistant_turn_finished", enabled: false, channelIds: null },
    ]);
    setPref(db, { id: editorId }, familyId, { event: "shopping_reminder", enabled: true, channelIds: [phone] }, NOW);
    expect(getPref(db, familyId, "shopping_reminder")).toEqual({ event: "shopping_reminder", enabled: true, channelIds: [phone] });
    expect(() => setPref(db, { id: viewerId }, familyId, { event: "coverage_gap", enabled: false, channelIds: null }, NOW)).toThrow(
      expect.objectContaining({ status: 403 }),
    );
    const other = makeFamily(db, makeUser(db).id);
    const theirs = createChannel(
      db,
      { admin: true, id: "x" },
      other.id,
      { name: "x", provider: "PUSHBULLET", token: "t", target: "", smtpHost: "", smtpPort: 465, smtpUsername: "", smtpFrom: "", enabled: true },
      NOW,
    ).id;
    expect(() => setPref(db, { id: editorId }, familyId, { event: "coverage_gap", enabled: true, channelIds: [theirs] }, NOW)).toThrow();
    expect(() => setPref(db, { id: editorId }, familyId, { event: "nope", enabled: true, channelIds: null }, NOW)).toThrow();
  });
});

describe("coverage alert", () => {
  // NOW's year (2026) has the preset types; add one that needs cover.
  function closure(days: string[]) {
    db.insert(schema.calEntryTypes)
      .values({ familyId, year: 2026, id: "kita", name: "Kita closed", color: "#ff0000", role: "needs_cover", position: 5 })
      .onConflictDoNothing()
      .run();
    for (const day of days) db.insert(schema.calEntries).values({ familyId, day, year: 2026, typeId: "kita" }).onConflictDoNothing().run();
  }
  function cover(day: string) {
    db.insert(schema.calEntries).values({ familyId, day, year: 2026, typeId: "vacation" }).run();
  }
  const check = (today: string, send = ok) => checkCoverage(db, familyId, NOW, { today, send });

  it("lists uncovered weekdays in the next 14 days", async () => {
    closure(["2026-11-03", "2026-11-04", "2026-11-07", "2026-11-20"]); // 7th: a Saturday; 20th: too far
    cover("2026-11-04");
    expect([...(await uncoveredDays(db, familyId, "2026-11-02"))]).toEqual([["2026-11-03", ["Kita closed"]]]);
  });

  it("tells once per new set of days, and again when a day loses its cover", async () => {
    closure(["2026-11-03", "2026-11-04"]);
    expect(await check("2026-11-02")).toEqual(["2026-11-03", "2026-11-04"]);
    expect(sent).toHaveLength(2); // both channels
    expect(sent[0].msg.title).toBe("2 days without cover in the next two weeks");
    expect(sent[0].msg.body).toContain("(Kita closed)");
    expect(sent[0].msg.url).toMatch(new RegExp(`/f/${familyId}/calendar$`));

    // The same day again, and the next day with the same days: nothing.
    expect(await check("2026-11-02")).toEqual([]);
    expect(await check("2026-11-03")).toEqual([]);
    expect(sent).toHaveLength(2);

    // A new closure: one message with all of them, the new one marked.
    closure(["2026-11-10"]);
    sent.length = 0;
    expect(await check("2026-11-04")).toEqual(["2026-11-04", "2026-11-10"]);
    expect(sent[0].msg.body).toMatch(/10 Nov \(Kita closed\) – new/);
    expect(sent[0].msg.body).not.toMatch(/4 Nov \(Kita closed\) – new/);

    // Covered, then uncovered again: told again.
    cover("2026-11-10");
    sent.length = 0;
    expect(await check("2026-11-05")).toEqual([]);
    db.delete(schema.calEntries).run();
    closure(["2026-11-10"]);
    expect(await check("2026-11-06")).toEqual(["2026-11-10"]);
    expect(sent).toHaveLength(2);
  });

  it("goes to the chosen channels, stays quiet when off, and retries after a failed send", async () => {
    closure(["2026-11-03"]);
    setPref(db, { id: editorId }, familyId, { event: "coverage_gap", enabled: true, channelIds: [mail] }, NOW);
    await check("2026-11-02", failing);
    expect(sent).toHaveLength(0);
    expect(await check("2026-11-03")).toEqual(["2026-11-03"]); // the next day: retried
    expect(sent.map((s) => s.channel.token)).toEqual(["tok"]);
    expect(sent).toHaveLength(1);

    closure(["2026-11-05"]);
    setPref(db, { id: editorId }, familyId, { event: "coverage_gap", enabled: false, channelIds: null }, NOW);
    sent.length = 0;
    expect(await check("2026-11-04")).toEqual([]);
    expect(sent).toHaveLength(0);
  });
});

describe("shopping reminder", () => {
  function plan() {
    db.insert(schema.units).values({ id: 1, nameEn: "gram", nameDe: "Gramm", abbreviation: "g", conversionFactor: "1" }).run();
    db.insert(schema.ingredients).values({ id: 1, nameEn: "Tomato", nameDe: "Tomate", category: "PRODUCE" }).run();
    db.insert(schema.recipes)
      .values({ id: "r1", familyId, title: "Soup", description: "", listType: "KNOWN", defaultServings: 2, createdAt: NOW, updatedAt: NOW })
      .run();
    db.insert(schema.recipeIngredients).values({ recipeId: "r1", ingredientId: 1, quantity: "250", unitId: 1, order: 0 }).run();
    // Monday 2026-06-01, shopping on Mondays and Thursdays.
    setupMealPlan(
      db,
      familyId,
      { iterationWeeks: 1, shoppingDays: [0, 3], servings: 2, knownRatio: 1, defaultLeftoverDays: 1, excludedTagIds: [] },
      new Date("2026-06-01T08:00:00Z"),
      mulberry32(1),
    );
  }
  const remind = (today: string) => remindShopping(db, familyId, NOW, { today, send: ok });

  it("is off by default; on, it sends tomorrow's list once", async () => {
    plan();
    expect(await remind("2026-06-03")).toBe(false);
    expect(sent).toHaveLength(0);
    setPref(db, { id: editorId }, familyId, { event: "shopping_reminder", enabled: true, channelIds: [phone] }, NOW);
    expect(await remind("2026-06-02")).toBe(false); // no shopping on Wednesday
    expect(await remind("2026-06-03")).toBe(true);
    expect(sent).toHaveLength(1);
    expect(sent[0].msg.title).toMatch(/^Shopping tomorrow: \d+ items?$/);
    expect(sent[0].msg.body).toMatch(/• \d+ g Tomato/);
    expect(sent[0].msg.url).toMatch(new RegExp(`/f/${familyId}/meals/shopping/`));
    expect(await remind("2026-06-03")).toBe(false);
    expect(sent).toHaveLength(1);
  });
});

describe("appointment notifications", () => {
  it("can be turned off for the family", async () => {
    const s = makeSearch(db, familyId, { name: "Derm" });
    db.insert(schema.apptSearchChannels).values({ searchId: s.id, channelId: phone }).run();
    setPref(db, { id: editorId }, familyId, { event: "appointment_found", enabled: false, channelIds: null }, NOW);
    const run = makeRun(db, s.id);
    makeResult(db, run.id, { doctorName: "Dr A" });
    expect(await notifyRun(db, run.id, { send: ok, now: NOW })).toBe(false);
    expect(sent).toHaveLength(0);
    setPref(db, { id: editorId }, familyId, { event: "appointment_found", enabled: true, channelIds: null }, NOW);
    expect(await notifyRun(db, run.id, { send: ok, now: NOW })).toBe(true);
    expect(sent).toHaveLength(1); // the search's channel only
  });
});
