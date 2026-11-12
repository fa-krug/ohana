// The app icon's number (lib/chores/badge.ts): the account's open chores already due (from their
// time, else from when their part of the day starts) and the overdue single ones, assigned to it
// or subscribed, in its families but the muted ones, with the moments it changes; sent with every
// push and answered by GET /api/v1/me/badge. The relay is a fake.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { handleAccountApp } from "@/lib/auth/app-routes";
import { createToken } from "@/lib/auth/tokens";
import { choreBadge, choreBadges } from "@/lib/chores/badge";
import { setDayParts } from "@/lib/chores/day-parts";
import { createChore, setChoreDone } from "@/lib/chores/chores";
import type { Db } from "@/lib/db";
import { DEFAULT_PUSH_RELAY_URL } from "@/lib/push/config";
import { pushToFamily } from "@/lib/push/deliver";
import { registerDevice } from "@/lib/push/devices";
import { openPayload } from "@/lib/push/payload";
import type { RelayClient, RelayMessage } from "@/lib/push/relay";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const TODAY = "2026-11-02";
/** Late on TODAY: every chore of the day is due. */
const LATE = { day: TODAY, time: "23:00" };
const on = (day: string, time = "23:00") => ({ day, time });
const keyOf = (n: number) => Buffer.alloc(32, n);

let db: Db;
let annaId: string;
let benId: string;
let familyId: string;
let otherFamilyId: string;

function chore(body: Record<string, unknown>, family = familyId) {
  return createChore(db, family, { title: "Bins", day: TODAY, subscriberIds: [], ...body }, { createdById: annaId }, NOW, TODAY);
}

beforeEach(() => {
  db = createTestDb();
  annaId = makeUser(db, { name: "Anna" }).id;
  benId = makeUser(db, { name: "Ben" }).id;
  familyId = makeFamily(db, annaId, [{ userId: benId, role: "editor" }]).id;
  otherFamilyId = makeFamily(db, annaId).id;
});

afterEach(() => {
  delete process.env.DISABLED_MODULES;
});

describe("choreBadge", () => {
  it("counts today's open chores assigned to or subscribed by the account, and overdue single ones", () => {
    chore({ assigneeId: annaId });
    chore({ subscriberIds: [annaId] });
    chore({ assigneeId: annaId, day: "2026-10-30" }); // overdue
    chore({ assigneeId: annaId, day: "2026-11-03" }); // tomorrow
    chore({ assigneeId: benId }); // Ben's
    chore({}); // nobody's
    const daily = chore({ assigneeId: annaId, day: "2026-10-01", rrule: "FREQ=DAILY" });
    chore({ assigneeId: annaId, day: "2026-10-01", rrule: "FREQ=WEEKLY;BYDAY=TU" }); // not today (a Monday)
    expect(choreBadge(db, annaId, LATE)).toBe(4);
    expect(choreBadge(db, benId, LATE)).toBe(1);

    setChoreDone(db, familyId, daily.id, true, { day: TODAY, userId: annaId }, NOW, TODAY);
    expect(choreBadge(db, annaId, LATE)).toBe(3);
    // A day later: today's two open single chores are overdue, tomorrow's is due, and the
    // weekly one too (a Tuesday); yesterday's daily occurrence, open or not, isn't overdue.
    expect(choreBadge(db, annaId, on("2026-11-03"))).toBe(6);
    // Both at once, for the switch at midnight; the day's chores (the day part, from 12:00) are
    // due tomorrow at noon.
    expect(choreBadges(db, annaId, LATE)).toEqual({
      count: 3,
      tomorrow: { day: "2026-11-03", count: 3 },
      steps: [{ at: "2026-11-03T12:00", count: 6 }],
    });
  });

  it("counts a chore only from its time, else from when its part of the day starts", () => {
    chore({ assigneeId: annaId, part: "morning" }); // from 07:00
    chore({ assigneeId: annaId, part: "evening" }); // from 18:00
    chore({ assigneeId: annaId, time: "09:30" });
    chore({ assigneeId: annaId, day: "2026-10-01", rrule: "FREQ=DAILY", part: "evening" });
    chore({ assigneeId: annaId, day: "2026-10-30", part: "evening" }); // overdue: always
    expect(choreBadge(db, annaId, on(TODAY, "06:59"))).toBe(1);
    expect(choreBadge(db, annaId, on(TODAY, "07:00"))).toBe(2);
    expect(choreBadge(db, annaId, on(TODAY, "09:30"))).toBe(3);
    expect(choreBadge(db, annaId, on(TODAY, "17:59"))).toBe(3);
    expect(choreBadge(db, annaId, on(TODAY, "18:00"))).toBe(5);
    // Each change from now to the end of tomorrow: midnight drops the daily one (today's single
    // ones stay, overdue), tomorrow evening it's due again.
    expect(choreBadges(db, annaId, on(TODAY, "06:00"))).toEqual({
      count: 1,
      tomorrow: { day: "2026-11-03", count: 4 },
      steps: [
        { at: "2026-11-02T07:00", count: 2 },
        { at: "2026-11-02T09:30", count: 3 },
        { at: "2026-11-02T18:00", count: 5 },
        { at: "2026-11-03T00:00", count: 4 },
        { at: "2026-11-03T18:00", count: 5 },
      ],
    });
    // The family's own day parts.
    setDayParts(db, familyId, { morning: "06:00", evening: "20:00" }, NOW);
    expect(choreBadge(db, annaId, on(TODAY, "06:00"))).toBe(2);
    expect(choreBadge(db, annaId, on(TODAY, "19:00"))).toBe(3);
  });

  it("leaves out what's done, and doesn't step when the number stays", () => {
    const morning = chore({ assigneeId: annaId, part: "morning" });
    const daily = chore({ assigneeId: annaId, day: "2026-10-01", rrule: "FREQ=DAILY", part: "morning" });
    setChoreDone(db, familyId, morning.id, true, { userId: annaId }, NOW, TODAY);
    setChoreDone(db, familyId, daily.id, true, { day: TODAY, userId: annaId }, NOW, TODAY);
    expect(choreBadges(db, annaId, on(TODAY, "06:00"))).toEqual({
      count: 0,
      tomorrow: { day: "2026-11-03", count: 0 },
      steps: [{ at: "2026-11-03T07:00", count: 1 }],
    });
  });

  it("adds up the account's families but the muted ones, and is 0 with chores off", () => {
    chore({ assigneeId: annaId });
    const done = chore({ assigneeId: annaId });
    setChoreDone(db, familyId, done.id, true, { userId: annaId }, NOW, TODAY);
    chore({ assigneeId: annaId }, otherFamilyId);
    expect(choreBadge(db, annaId, LATE)).toBe(2);
    expect(choreBadge(db, annaId, LATE, [otherFamilyId])).toBe(1);
    process.env.DISABLED_MODULES = "chores";
    expect(choreBadge(db, annaId, LATE)).toBe(0);
  });
});

describe("with pushes and the app", () => {
  let tokens: Record<number, string>;
  const messages: RelayMessage[] = [];
  const relay: RelayClient = {
    async send(_url, batch) {
      messages.push(...batch);
      return batch.map(() => ({ status: "ok" as const }));
    },
  };

  function device(userId: string, n: number, muted: string[] = []) {
    const { row, token } = createToken(db, { userId, kind: "api", name: `Device ${n}` }, NOW);
    registerDevice(
      db,
      { id: userId },
      row.id,
      { relay: DEFAULT_PUSH_RELAY_URL, relayToken: `r1.${n}`, key: keyOf(n).toString("base64"), platform: "ios", mutedFamilyIds: muted },
      NOW,
    );
    tokens[n] = token;
  }

  beforeEach(() => {
    tokens = {};
    messages.length = 0;
    device(annaId, 1);
    device(annaId, 2, [otherFamilyId]);
    device(benId, 3);
    chore({ assigneeId: annaId });
    chore({ assigneeId: annaId }, otherFamilyId);
  });

  it("puts each device's number into its push", async () => {
    const now = new Date(2026, 10, 2, 9, 0); // server-local TODAY
    await pushToFamily(db, familyId, { title: "T", body: "B" }, { relay, now });
    const opened = (n: number) => openPayload(keyOf(n), messages.find((m) => m.relayToken === `r1.${n}`)!.payload);
    // The chores (the day part) are due at 12:00 (server-local).
    expect(opened(1)).toMatchObject({
      badge: 0,
      badgeTomorrow: { day: "2026-11-03", count: 2 },
      badgeSteps: [{ at: "2026-11-02T12:00", count: 2 }],
    });
    expect(opened(2)).toMatchObject({ badge: 0, badgeSteps: [{ at: "2026-11-02T12:00", count: 1 }] });
    expect(opened(3)).toMatchObject({ badge: 0, badgeTomorrow: { day: "2026-11-03", count: 0 }, badgeSteps: [] });
    messages.length = 0;
    await pushToFamily(db, familyId, { title: "T", body: "B" }, { relay, now: new Date(2026, 10, 2, 12, 0) });
    expect(opened(1)).toMatchObject({ badge: 2, badgeSteps: [] });
  });

  it("answers GET /me/badge for the calling device", async () => {
    const get = async (n: number, query = `?today=${TODAY}`) => {
      const res = await handleAccountApp(
        db,
        new Request(`http://ohana.test/api/v1/me/badge${query}`, { headers: { authorization: `Bearer ${tokens[n]}` } }),
        ["badge"],
        NOW,
      );
      return { status: res.status, data: await res.json() };
    };
    expect(await get(1, `?today=${TODAY}&time=13:00`)).toEqual({
      status: 200,
      data: { count: 2, tomorrow: { day: "2026-11-03", count: 2 }, steps: [] },
    });
    expect((await get(1, `?today=${TODAY}&time=11:59`)).data).toEqual({
      count: 0,
      tomorrow: { day: "2026-11-03", count: 2 },
      steps: [{ at: "2026-11-02T12:00", count: 2 }],
    });
    expect((await get(2, `?today=${TODAY}&time=13:00`)).data).toMatchObject({ count: 1 });
    expect((await get(3, `?today=${TODAY}&time=13:00`)).data).toMatchObject({ count: 0 });
    // Without a time: a day after the server's from its start, one before to its end.
    // (The server's day is NOW's, 2026-11-01: before TODAY.)
    expect((await get(1)).data).toMatchObject({ count: 0, steps: [{ at: "2026-11-02T12:00", count: 2 }] });
    expect((await get(1, "?today=2026-11-03")).data).toMatchObject({ count: 2 });
    expect((await get(1, "")).data).toMatchObject({ count: 0, tomorrow: { day: "2026-11-02", count: 0 } });
    expect((await get(1, "?today=tomorrow")).status).toBe(400);
    expect((await get(1, `?today=${TODAY}&time=7`)).status).toBe(400);
  });
});
