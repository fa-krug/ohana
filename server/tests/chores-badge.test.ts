// The app icon's number (lib/chores/badge.ts): the account's open chores due today and the
// overdue single ones, assigned to it or subscribed, in its families but the muted ones; sent
// with every push and answered by GET /api/v1/me/badge. The relay is a fake.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { handleAccountApp } from "@/lib/auth/app-routes";
import { createToken } from "@/lib/auth/tokens";
import { choreBadge, choreBadges } from "@/lib/chores/badge";
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
    expect(choreBadge(db, annaId, TODAY)).toBe(4);
    expect(choreBadge(db, benId, TODAY)).toBe(1);

    setChoreDone(db, familyId, daily.id, true, { day: TODAY, userId: annaId }, NOW, TODAY);
    expect(choreBadge(db, annaId, TODAY)).toBe(3);
    // A day later: today's two open single chores are overdue, tomorrow's is due, and the
    // weekly one too (a Tuesday); yesterday's daily occurrence, open or not, isn't overdue.
    expect(choreBadge(db, annaId, "2026-11-03")).toBe(6);
    // Both at once, for the switch at midnight.
    expect(choreBadges(db, annaId, TODAY)).toEqual({ count: 3, tomorrow: { day: "2026-11-03", count: 6 } });
  });

  it("adds up the account's families but the muted ones, and is 0 with chores off", () => {
    chore({ assigneeId: annaId });
    const done = chore({ assigneeId: annaId });
    setChoreDone(db, familyId, done.id, true, { userId: annaId }, NOW, TODAY);
    chore({ assigneeId: annaId }, otherFamilyId);
    expect(choreBadge(db, annaId, TODAY)).toBe(2);
    expect(choreBadge(db, annaId, TODAY, [otherFamilyId])).toBe(1);
    process.env.DISABLED_MODULES = "chores";
    expect(choreBadge(db, annaId, TODAY)).toBe(0);
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
    expect(opened(1)).toMatchObject({ badge: 2, badgeTomorrow: { day: "2026-11-03", count: 2 } });
    expect(opened(2)).toMatchObject({ badge: 1, badgeTomorrow: { day: "2026-11-03", count: 1 } });
    expect(opened(3)).toMatchObject({ badge: 0, badgeTomorrow: { day: "2026-11-03", count: 0 } });
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
    expect(await get(1)).toEqual({ status: 200, data: { count: 2, tomorrow: { day: "2026-11-03", count: 2 } } });
    expect((await get(2)).data).toMatchObject({ count: 1 });
    expect((await get(3)).data).toMatchObject({ count: 0 });
    expect((await get(1, "?today=tomorrow")).status).toBe(400);
  });
});
