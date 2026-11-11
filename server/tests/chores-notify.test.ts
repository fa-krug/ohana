// "A chore is due" (lib/chores/notify.ts): the due moment (its time, else its part of the day's),
// the 3-hour window, done ones skipped, each day told once, only the subscribers' devices, the
// text and link, and nothing with the module off. Days and moments are the server's local ones;
// "now" is passed in. The relay is a fake.

import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createToken } from "@/lib/auth/tokens";
import { createChore, setChoreDone, updateChore } from "@/lib/chores/chores";
import { DEFAULT_DAY_PARTS, setDayParts } from "@/lib/chores/day-parts";
import { DUE_WINDOW_MS, choreNotifications, dueMoment } from "@/lib/chores/notify";
import type { Db } from "@/lib/db";
import * as schema from "@/lib/db/schema";
import { addPerson } from "@/lib/families/people";
import { DEFAULT_PUSH_RELAY_URL } from "@/lib/push/config";
import { registerDevice } from "@/lib/push/devices";
import { openPayload } from "@/lib/push/payload";
import type { RelayClient, RelayMessage } from "@/lib/push/relay";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

let db: Db;
let annaId: string;
let benId: string;
let familyId: string;
let relay: ReturnType<typeof fakeRelay>;

const keyOf = (n: number) => Buffer.alloc(32, n);

function fakeRelay() {
  const messages: RelayMessage[] = [];
  const client: RelayClient = {
    async send(_url, batch) {
      messages.push(...batch);
      return batch.map(() => ({ status: "ok" as const }));
    },
  };
  return { client, messages };
}

function device(userId: string, n: number) {
  const { row } = createToken(db, { userId, kind: "api", name: `Device ${n}` }, NOW);
  registerDevice(
    db,
    { id: userId },
    row.id,
    { relay: DEFAULT_PUSH_RELAY_URL, relayToken: `r1.${n}`, key: keyOf(n).toString("base64"), platform: "ios" },
    NOW,
  );
}

/** What the device `n` got, opened. */
const received = (n: number) =>
  relay.messages.filter((m) => m.relayToken === `r1.${n}`).map((m) => openPayload(keyOf(n), m.payload));

/** A server-local moment. */
const at = (day: string, time: string) => {
  const [y, m, d] = day.split("-").map(Number);
  const [hh, mm] = time.split(":").map(Number);
  return new Date(y, m - 1, d, hh, mm);
};

const TODAY = "2026-11-02";

function chore(body: Record<string, unknown>, by = annaId) {
  return createChore(db, familyId, { title: "Bins", day: TODAY, ...body }, { createdById: by }, NOW, TODAY);
}

const run = (day: string, time: string) => choreNotifications(db, at(day, time), { push: relay.client });

beforeEach(() => {
  db = createTestDb();
  annaId = makeUser(db, { name: "Anna" }).id;
  benId = makeUser(db, { name: "Ben" }).id;
  familyId = makeFamily(db, annaId, [{ userId: benId, role: "viewer" }]).id;
  device(annaId, 1);
  device(benId, 2);
  relay = fakeRelay();
});

afterEach(() => {
  delete process.env.DISABLED_MODULES;
});

describe("dueMoment", () => {
  it("is the time, else the part's", () => {
    expect(dueMoment({ time: "18:30", part: "evening" }, TODAY)).toEqual(at(TODAY, "18:30"));
    expect(dueMoment({ time: null, part: "morning" }, TODAY)).toEqual(at(TODAY, "07:00"));
    expect(dueMoment({ time: null, part: "day" }, TODAY)).toEqual(at(TODAY, "12:00"));
    expect(dueMoment({ time: null, part: "evening" }, TODAY)).toEqual(at(TODAY, "18:00"));
    expect(DEFAULT_DAY_PARTS).toEqual({ morning: "07:00", day: "12:00", evening: "18:00" });
    const parts = { morning: "06:30", day: "11:00", evening: "19:15" };
    expect(dueMoment({ time: null, part: "morning" }, TODAY, parts)).toEqual(at(TODAY, "06:30"));
    expect(dueMoment({ time: null, part: "evening" }, TODAY, parts)).toEqual(at(TODAY, "19:15"));
    expect(DUE_WINDOW_MS).toBe(3 * 60 * 60 * 1000);
  });
});

describe("choreNotifications", () => {
  it("tells a chore without a time when its part starts in the family", async () => {
    setDayParts(db, familyId, { morning: "06:00", day: "11:00", evening: "19:30" }, NOW);
    chore({ part: "evening" });
    expect(await run(TODAY, "19:29")).toEqual([]);
    expect(await run(TODAY, "19:30")).toHaveLength(1);
  });

  it("tells the subscribers once its time has come, once", async () => {
    const c = chore({ time: "18:00" });
    expect(await run(TODAY, "17:59")).toEqual([]);
    expect(relay.messages).toEqual([]);

    expect(await run(TODAY, "18:00")).toEqual([{ choreId: c.id, day: TODAY, userIds: [annaId] }]);
    // Only Anna subscribed (the creator); Ben's device gets nothing.
    expect(received(2)).toEqual([]);
    expect(received(1)).toEqual([
      {
        v: 1,
        title: "Bins",
        body: "Due at 18:00",
        path: `/f/${familyId}/chores/${c.id}?day=${TODAY}`,
        familyId,
        event: "chore_due",
        // The icon's number: this chore, open and Anna's (lib/chores/badge.ts).
        badge: 1,
        // Still open tomorrow, then overdue (the day: the real clock's, notifyFamily passes none).
        badgeTomorrow: { day: expect.any(String), count: 1 },
      },
    ]);
    expect(relay.messages[0].collapseId).toEqual(expect.any(String));
    // Once.
    expect(await run(TODAY, "18:01")).toEqual([]);
    expect(relay.messages).toHaveLength(1);
    expect(db.select().from(schema.choreNotified).all()).toEqual([{ choreId: c.id, day: TODAY, sentAt: at(TODAY, "18:00") }]);
  });

  it("is due at its part of the day's moment without a time", async () => {
    const morning = chore({ title: "Beds", part: "morning" });
    const day = chore({ title: "Lunch" });
    const evening = chore({ title: "Dishes", part: "evening" });
    expect(await run(TODAY, "06:59")).toEqual([]);
    expect((await run(TODAY, "07:00")).map((n) => n.choreId)).toEqual([morning.id]);
    expect((await run(TODAY, "12:30")).map((n) => n.choreId)).toEqual([day.id]);
    expect((await run(TODAY, "18:00")).map((n) => n.choreId)).toEqual([evening.id]);
    expect(received(1).map((p) => [p.title, p.body])).toEqual([
      ["Beds", "Due now"],
      ["Lunch", "Due now"],
      ["Dishes", "Due now"],
    ]);
  });

  it("isn't told more than 3 hours late", async () => {
    chore({ time: "14:00" });
    expect(await run(TODAY, "17:01")).toEqual([]);
    expect(relay.messages).toEqual([]);
    // Not remembered either: it simply passed.
    expect(db.select().from(schema.choreNotified).all()).toEqual([]);
    const c = chore({ title: "Car", time: "14:01" });
    expect((await run(TODAY, "17:01")).map((n) => n.choreId)).toEqual([c.id]);
  });

  it("tells yesterday's late ones after midnight, and each occurrence of a repeating one", async () => {
    const c = chore({ title: "Lock up", time: "23:30", day: "2026-11-01", rrule: "FREQ=DAILY" });
    expect(await run("2026-11-02", "00:15")).toEqual([{ choreId: c.id, day: "2026-11-01", userIds: [annaId] }]);
    expect(received(1)[0].path).toBe(`/f/${familyId}/chores/${c.id}?day=2026-11-01`);
    expect(await run("2026-11-02", "23:30")).toEqual([{ choreId: c.id, day: "2026-11-02", userIds: [annaId] }]);
    // Not on days that aren't occurrences.
    const weekly = chore({ title: "Vacuum", time: "10:00", day: "2026-11-02", rrule: "FREQ=WEEKLY" });
    expect(await run("2026-11-03", "10:00")).toEqual([]);
    expect((await run("2026-11-09", "10:00")).map((n) => n.choreId)).toEqual([weekly.id]);
  });

  it("skips done ones", async () => {
    const single = chore({ time: "18:00" });
    setChoreDone(db, familyId, single.id, true, { userId: annaId }, NOW, TODAY);
    const daily = chore({ title: "Cat", time: "18:00", rrule: "FREQ=DAILY" });
    setChoreDone(db, familyId, daily.id, true, { day: TODAY, userId: annaId }, NOW, TODAY);
    expect(await run(TODAY, "18:10")).toEqual([]);
    // Tomorrow's occurrence is open.
    expect(await run("2026-11-03", "18:10")).toEqual([{ choreId: daily.id, day: "2026-11-03", userIds: [annaId] }]);
  });

  it("goes to every subscriber, and names whom it is for", async () => {
    const mia = addPerson(db, { id: annaId }, familyId, { name: "Mia" }, NOW).person;
    chore({ title: "Feed the cat", assigneeId: mia.id, subscriberIds: [annaId, benId] });
    chore({ title: "Homework", assigneeId: benId, subscriberIds: [benId], part: "morning" });
    chore({ title: "Laundry", assigneeId: benId, subscriberIds: [annaId, benId], part: "evening" });
    chore({ title: "Nobody's", subscriberIds: [] });
    await run(TODAY, "07:00");
    await run(TODAY, "12:00");
    await run(TODAY, "18:00");
    expect(received(1).map((p) => [p.title, p.body])).toEqual([
      ["Feed the cat", "Due now · for Mia"],
      ["Laundry", "Due now · for Ben"],
    ]);
    expect(received(2).map((p) => [p.title, p.body])).toEqual([
      ["Homework", "Due now"], // Ben is the only one told: not "for Ben"
      ["Feed the cat", "Due now · for Mia"],
      ["Laundry", "Due now · for Ben"],
    ]);
  });

  it("is written in the family's language", async () => {
    db.update(schema.users).set({ preferredLanguage: "de" }).where(eq(schema.users.id, annaId)).run();
    chore({ time: "18:00", assigneeId: benId });
    await run(TODAY, "18:00");
    expect(received(1)[0].body).toBe("Fällig um 18:00 · für Ben");
  });

  it("tells again after the chore was moved", async () => {
    const c = chore({ time: "08:00" });
    expect(await run(TODAY, "08:00")).toHaveLength(1);
    updateChore(db, familyId, c.id, { time: "09:00" }, NOW, TODAY);
    expect(await run(TODAY, "09:00")).toHaveLength(1);
    // A change of the title alone doesn't.
    updateChore(db, familyId, c.id, { title: "Bins!" }, NOW, TODAY);
    expect(await run(TODAY, "09:01")).toEqual([]);
  });

  it("does nothing with the module off", async () => {
    chore({ time: "18:00" });
    process.env.DISABLED_MODULES = "chores";
    expect(await run(TODAY, "18:00")).toEqual([]);
    expect(relay.messages).toEqual([]);
    expect(db.select().from(schema.choreNotified).all()).toEqual([]);
  });
});
