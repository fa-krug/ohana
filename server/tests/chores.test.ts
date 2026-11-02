// Chores (/families/{id}/chores…): roles, checks, `next`, the part of the day, done (a single
// chore, a repeating one's occurrences), subscriptions, the agenda, and what happens to a
// chore's assignee and subscribers when a person accepts their invite or a member leaves.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import { createFamilyApi } from "@/lib/api/family-api";
import { handleDisabledModules } from "@/lib/api/disabled-modules";
import { createToken } from "@/lib/auth/tokens";
import { handleChores } from "@/lib/chores/routes";
import { acceptInvite } from "@/lib/families/invites";
import { removeMember } from "@/lib/families/members";
import { addPerson } from "@/lib/families/people";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const BASE = "http://ohana.test/api/v1";

let db: Db;
let editorId: string;
let viewerId: string;
let familyId: string;

function call(userId: string, family = familyId) {
  const handler = createFamilyApi([handleDisabledModules, handleChores], { db, appUrl: "http://ohana.test", now: () => NOW });
  const token = createToken(db, { userId, kind: "api" }, NOW).token;
  return async (method: string, path: string, body?: unknown) => {
    const res = await handler(
      new Request(BASE + `/families/${family}` + path, {
        method,
        headers: {
          authorization: `Bearer ${token}`,
          ...(body !== undefined ? { "content-type": "application/json" } : {}),
        },
        body: body !== undefined ? JSON.stringify(body) : undefined,
      }),
    );
    return { status: res.status, data: await res.json() };
  };
}

beforeEach(() => {
  db = createTestDb();
  editorId = makeUser(db, { name: "Anna" }).id;
  viewerId = makeUser(db, { name: "Ben" }).id;
  familyId = makeFamily(db, editorId, [{ userId: viewerId, role: "viewer" }]).id;
});

afterEach(() => {
  delete process.env.DISABLED_MODULES;
});

describe("chores", () => {
  it("are added, read, changed and deleted by editors", async () => {
    const edit = call(editorId);
    const created = await edit("POST", "/chores", { title: " Take out the bins ", note: "Blue one", assigneeId: viewerId, day: "2026-11-03", time: "18:00" });
    expect(created.status).toBe(201);
    const { chore } = created.data;
    expect(chore).toEqual({
      id: expect.any(String),
      title: "Take out the bins",
      note: "Blue one",
      assignee: { id: viewerId, name: "Ben", account: true },
      day: "2026-11-03",
      time: "18:00",
      part: "evening",
      rrule: null,
      done: false,
      doneAt: null,
      doneBy: null,
      next: "2026-11-03",
      subscriberIds: [editorId],
      subscribed: true,
      createdAt: NOW.toISOString(),
      updatedAt: NOW.toISOString(),
    });

    const list = await edit("GET", "/chores");
    expect(list.status).toBe(200);
    expect(list.data).toEqual({
      chores: [chore],
      people: [
        { id: editorId, name: "Anna", account: true },
        { id: viewerId, name: "Ben", account: true },
      ],
      canEdit: true,
    });
    expect((await edit("GET", `/chores/${chore.id}`)).data).toEqual({ chore });

    const changed = await edit("PATCH", `/chores/${chore.id}`, { title: "Bins", time: null, assigneeId: null });
    expect(changed.status).toBe(200);
    expect(changed.data.chore).toMatchObject({ title: "Bins", note: "Blue one", time: null, part: "evening", assignee: null, day: "2026-11-03" });
    // Someone else sees it as not subscribed.
    expect((await call(viewerId)("GET", `/chores/${chore.id}`)).data.chore).toMatchObject({ subscriberIds: [editorId], subscribed: false });

    expect(await edit("DELETE", `/chores/${chore.id}`)).toEqual({ status: 200, data: { deleted: chore.id } });
    expect((await edit("GET", `/chores/${chore.id}`)).status).toBe(404);
    expect((await edit("DELETE", `/chores/${chore.id}`)).status).toBe(404);
  });

  it("are read by viewers, changed only by editors; non-members see nothing", async () => {
    const { data } = await call(editorId)("POST", "/chores", { title: "Dishes", day: "2026-11-02" });
    const view = call(viewerId);
    const list = await view("GET", "/chores");
    expect(list.status).toBe(200);
    expect(list.data.canEdit).toBe(false);
    expect(list.data.chores).toHaveLength(1);
    expect((await view("POST", "/chores", { title: "x", day: "2026-11-02" })).status).toBe(403);
    expect((await view("PATCH", `/chores/${data.chore.id}`, { title: "x" })).status).toBe(403);
    expect((await view("DELETE", `/chores/${data.chore.id}`)).status).toBe(403);

    const stranger = call(makeUser(db).id);
    expect((await stranger("GET", "/chores")).status).toBe(404);
    expect((await stranger("GET", `/chores/${data.chore.id}`)).status).toBe(404);
  });

  it("are marked done by editors, by viewers only when assigned to them", async () => {
    const edit = call(editorId);
    const view = call(viewerId);
    const mine = (await edit("POST", "/chores", { title: "Tidy up", day: "2026-10-30", assigneeId: viewerId })).data.chore;
    const theirs = (await edit("POST", "/chores", { title: "Groceries", day: "2026-10-30", assigneeId: editorId })).data.chore;
    expect((await view("POST", `/chores/${theirs.id}/done`, { done: true })).status).toBe(403);

    const done = await view("POST", `/chores/${mine.id}/done`, { done: true, day: "2000-01-01" }); // day ignored
    expect(done.status).toBe(200);
    const ben = { id: viewerId, name: "Ben", account: true };
    expect(done.data.chore).toMatchObject({ done: true, doneAt: NOW.toISOString(), doneBy: ben, next: null, updatedAt: NOW.toISOString() });
    // Done again keeps who did it first.
    expect((await edit("POST", `/chores/${mine.id}/done`, { done: true })).data.chore.doneBy).toEqual(ben);
    const open = await edit("POST", `/chores/${mine.id}/done`, { done: false });
    expect(open.data.chore).toMatchObject({ done: false, doneAt: null, doneBy: null, next: "2026-10-30" });
    expect((await edit("POST", `/chores/${mine.id}/done`, {})).status).toBe(400);
    expect((await edit("POST", "/chores/nope/done", { done: true })).status).toBe(404);
  });

  it("check their input", async () => {
    const edit = call(editorId);
    const bad = async (body: unknown) => (await edit("POST", "/chores", body)).status;
    expect(await bad({ day: "2026-11-02" })).toBe(400);
    expect(await bad({ title: "  ", day: "2026-11-02" })).toBe(400);
    expect(await bad({ title: "x".repeat(201), day: "2026-11-02" })).toBe(400);
    expect(await bad({ title: "x", day: "2026-11-02", note: "x".repeat(2001) })).toBe(400);
    expect(await bad({ title: "x", day: "2026-02-30" })).toBe(400);
    expect(await bad({ title: "x" })).toBe(400);
    expect(await bad({ title: "x", day: "2026-11-02", time: "25:00" })).toBe(400);
    expect(await bad({ title: "x", day: "2026-11-02", rrule: "FREQ=HOURLY" })).toBe(400);
    expect(await bad({ title: "x", day: "2026-11-02", assigneeId: makeUser(db).id })).toBe(400);
    expect(await bad({ title: "x", day: "2026-11-02", assigneeId: "nobody" })).toBe(400);
    // A person of another family isn't one of this family's.
    const otherFamily = makeFamily(db, editorId).id;
    const stranger = addPerson(db, { id: editorId }, otherFamily, { name: "Kim" }, NOW).person;
    expect(await bad({ title: "x", day: "2026-11-02", assigneeId: stranger.id })).toBe(400);
    expect((await edit("GET", "/chores?today=tomorrow")).status).toBe(400);
    expect((await edit("PUT", "/chores")).status).toBe(405);
    expect((await edit("GET", "/chores/x/y")).status).toBe(404);
    // "" and null are once; the rule is stored upper-case.
    const once = await edit("POST", "/chores", { title: "x", day: "2026-11-02", rrule: "" });
    expect(once.data.chore.rrule).toBeNull();
    const weekly = await edit("POST", "/chores", { title: "x", day: "2026-11-02", rrule: " freq=weekly;byday=mo " });
    expect(weekly.data.chore.rrule).toBe("FREQ=WEEKLY;BYDAY=MO");
  });

  it("are assigned to members without an account too", async () => {
    const mia = addPerson(db, { id: editorId }, familyId, { name: "Mia" }, NOW).person;
    const edit = call(editorId);
    const { data } = await edit("POST", "/chores", { title: "Feed the cat", day: "2026-11-02", assigneeId: mia.id });
    expect(data.chore.assignee).toEqual({ id: mia.id, name: "Mia", account: false });
    expect((await edit("GET", "/chores")).data.people).toContainEqual({ id: mia.id, name: "Mia", account: false });
  });

  it("work out what is due next", async () => {
    const edit = call(editorId);
    const add = async (body: Record<string, unknown>) => (await edit("POST", "/chores?today=2026-11-04", { title: "x", ...body })).data.chore;
    // Single: its day, also when it is past (overdue).
    expect((await add({ day: "2026-11-10" })).next).toBe("2026-11-10");
    expect((await add({ day: "2026-10-01" })).next).toBe("2026-10-01");
    // Repeating: the first occurrence from today on (the first one when it starts later).
    expect((await add({ day: "2026-11-02", rrule: "FREQ=WEEKLY;BYDAY=MO" })).next).toBe("2026-11-09");
    expect((await add({ day: "2026-11-04", rrule: "FREQ=DAILY" })).next).toBe("2026-11-04");
    expect((await add({ day: "2026-12-01", rrule: "FREQ=MONTHLY" })).next).toBe("2026-12-01");
    // An ended series has none.
    const ended = await add({ day: "2026-10-01", rrule: "FREQ=WEEKLY;COUNT=2" });
    expect(ended.next).toBeNull();
    expect((await add({ day: "2026-10-01", rrule: "FREQ=DAILY;UNTIL=20261103" })).next).toBeNull();

    // Sorted by next (none last), then title; today moves next along.
    const list = (await edit("GET", "/chores?today=2026-11-04")).data.chores.map((c: { next: string | null }) => c.next);
    expect(list).toEqual(["2026-10-01", "2026-11-04", "2026-11-09", "2026-11-10", "2026-12-01", null, null]);
    const later = await edit("GET", `/chores/${ended.id}?today=2026-09-01`);
    expect(later.data.chore.next).toBe("2026-10-01");
    // The server's day without ?today=.
    const daily = (await edit("GET", "/chores")).data.chores.find((c: { day: string; rrule: string | null }) => c.rrule === "FREQ=DAILY");
    expect(daily.next).toBe("2026-11-04");
  });

  it("take a part of the day: given, or from the time", async () => {
    const edit = call(editorId);
    const add = async (body: Record<string, unknown>) => (await edit("POST", "/chores", { title: "x", day: "2026-11-02", ...body })).data.chore;
    expect((await add({})).part).toBe("day");
    expect((await add({ part: "morning" })).part).toBe("morning");
    expect((await add({ time: "11:59" })).part).toBe("morning");
    expect((await add({ time: "12:00" })).part).toBe("day");
    expect((await add({ time: "16:59" })).part).toBe("day");
    expect((await add({ time: "17:00" })).part).toBe("evening");
    // A time wins over a given part.
    expect((await add({ time: "07:30", part: "evening" })).part).toBe("morning");
    expect((await edit("POST", "/chores", { title: "x", day: "2026-11-02", part: "night" })).status).toBe(400);
    // PATCH: a new time sets it, a part alone changes it, dropping the time keeps it.
    const c = await add({ part: "evening" });
    expect((await edit("PATCH", `/chores/${c.id}`, { time: "08:00" })).data.chore.part).toBe("morning");
    expect((await edit("PATCH", `/chores/${c.id}`, { part: "evening" })).data.chore.part).toBe("morning");
    expect((await edit("PATCH", `/chores/${c.id}`, { time: null })).data.chore.part).toBe("morning");
    expect((await edit("PATCH", `/chores/${c.id}`, { part: "evening" })).data.chore.part).toBe("evening");
  });

  it("are subscribed by their creator, or by whom the editor picks", async () => {
    const edit = call(editorId);
    const view = call(viewerId);
    const mia = addPerson(db, { id: editorId }, familyId, { name: "Mia" }, NOW).person;
    const mine = (await edit("POST", "/chores", { title: "Bins", day: "2026-11-02" })).data.chore;
    expect(mine.subscriberIds).toEqual([editorId]);
    const both = (await edit("POST", "/chores", { title: "Dishes", day: "2026-11-02", subscriberIds: [viewerId, editorId, viewerId] })).data.chore;
    expect(both).toMatchObject({ subscriberIds: [editorId, viewerId], subscribed: true });
    const none = (await edit("POST", "/chores", { title: "Car", day: "2026-11-02", subscriberIds: [] })).data.chore;
    expect(none).toMatchObject({ subscriberIds: [], subscribed: false });
    // Only accounts of the family.
    const bad = async (ids: unknown) => (await edit("POST", "/chores", { title: "x", day: "2026-11-02", subscriberIds: ids })).status;
    expect(await bad([mia.id])).toBe(400);
    expect(await bad([makeUser(db).id])).toBe(400);
    expect(await bad("all")).toBe(400);
    // PATCH: given, replaced; omitted, unchanged.
    expect((await edit("PATCH", `/chores/${both.id}`, { subscriberIds: [viewerId] })).data.chore.subscriberIds).toEqual([viewerId]);
    expect((await edit("PATCH", `/chores/${both.id}`, { title: "Dishes!" })).data.chore.subscriberIds).toEqual([viewerId]);
    expect((await edit("PATCH", `/chores/${both.id}`, { subscriberIds: [mia.id] })).status).toBe(400);

    // Any member subscribes themselves, viewers too.
    const sub = await view("POST", `/chores/${mine.id}/subscribe`, { subscribed: true });
    expect(sub.status).toBe(200);
    expect(sub.data.chore).toMatchObject({ subscriberIds: [editorId, viewerId], subscribed: true });
    expect((await view("POST", `/chores/${mine.id}/subscribe`, { subscribed: true })).data.chore.subscriberIds).toEqual([editorId, viewerId]);
    const unsub = await edit("POST", `/chores/${mine.id}/subscribe`, { subscribed: false });
    expect(unsub.data.chore).toMatchObject({ subscriberIds: [viewerId], subscribed: false });
    expect((await view("POST", `/chores/${mine.id}/subscribe`, {})).status).toBe(400);
    expect((await view("POST", "/chores/nope/subscribe", { subscribed: true })).status).toBe(404);
    expect((await view("GET", `/chores/${mine.id}/subscribe`)).status).toBe(405);
    expect((await call(makeUser(db).id)("POST", `/chores/${mine.id}/subscribe`, { subscribed: true })).status).toBe(404);
  });

  it("tick off a repeating chore per occurrence", async () => {
    const edit = call(editorId);
    const view = call(viewerId);
    const weekly = (await edit("POST", "/chores", { title: "Vacuum", day: "2026-11-02", rrule: "FREQ=WEEKLY;BYDAY=MO", assigneeId: viewerId })).data.chore;
    const other = (await edit("POST", "/chores", { title: "Mop", day: "2026-11-02", rrule: "FREQ=DAILY" })).data.chore;
    // A day is required and must be an occurrence.
    expect((await edit("POST", `/chores/${weekly.id}/done`, { done: true })).status).toBe(400);
    expect((await edit("POST", `/chores/${weekly.id}/done`, { done: true, day: "2026-11-03" })).status).toBe(400);
    expect((await edit("POST", `/chores/${weekly.id}/done`, { done: true, day: "2026-10-26" })).status).toBe(400); // before the first
    expect((await edit("POST", `/chores/${weekly.id}/done`, { done: true, day: "soon" })).status).toBe(400);
    // Viewers only their own.
    expect((await view("POST", `/chores/${other.id}/done`, { done: true, day: "2026-11-02" })).status).toBe(403);
    const done = await view("POST", `/chores/${weekly.id}/done`, { done: true, day: "2026-11-09" });
    expect(done.status).toBe(200);
    // The chore itself is never done.
    expect(done.data.chore).toMatchObject({ done: false, doneAt: null, doneBy: null, next: "2026-11-02" });
    expect((await edit("POST", `/chores/${weekly.id}/done`, { done: true, day: "2026-11-02" })).status).toBe(200);
    const agenda = async () =>
      (await edit("GET", "/chores/agenda?from=2026-11-02&to=2026-11-09")).data.days
        .flatMap((d: { items: { choreId: string; day: string; done: boolean; doneBy: unknown; doneAt: string | null }[] }) => d.items)
        .filter((i: { choreId: string }) => i.choreId === weekly.id);
    expect(await agenda()).toEqual([
      expect.objectContaining({ day: "2026-11-02", done: true, doneAt: NOW.toISOString(), doneBy: { id: editorId, name: "Anna", account: true } }),
      expect.objectContaining({ day: "2026-11-09", done: true, doneBy: { id: viewerId, name: "Ben", account: true } }),
    ]);
    // Open again; twice is fine.
    await view("POST", `/chores/${weekly.id}/done`, { done: false, day: "2026-11-09" });
    await view("POST", `/chores/${weekly.id}/done`, { done: false, day: "2026-11-09" });
    expect((await agenda()).map((i: { done: boolean }) => i.done)).toEqual([true, false]);
  });

  it("list the agenda by day, part and time, with what is overdue", async () => {
    const edit = call(editorId);
    const view = call(viewerId);
    const add = async (body: Record<string, unknown>) => (await edit("POST", "/chores", { day: "2026-11-02", ...body })).data.chore;
    const evening = await add({ title: "Bins", time: "19:00" });
    const late = await add({ title: "Alarm", part: "evening" });
    const morning = await add({ title: "Beds", part: "morning" });
    const day = await add({ title: "Zebra", time: "13:00" });
    const day2 = await add({ title: "Apples" });
    const daily = await add({ title: "Cat", rrule: "FREQ=DAILY", time: "08:00", subscriberIds: [viewerId] });
    const old = await add({ title: "Tax", day: "2026-10-20" });
    const older = await add({ title: "Car", day: "2026-10-01", part: "evening" });
    const doneOld = await add({ title: "Done", day: "2026-10-10" });
    await edit("POST", `/chores/${doneOld.id}/done`, { done: true });
    await add({ title: "Later", day: "2026-11-20" });

    const res = await view("GET", "/chores/agenda?from=2026-11-01&to=2026-11-03&today=2026-11-02");
    expect(res.status).toBe(200);
    const ids = (items: { choreId: string }[]) => items.map((i) => i.choreId);
    expect(res.data.days.map((d: { date: string }) => d.date)).toEqual(["2026-11-01", "2026-11-02", "2026-11-03"]);
    expect(res.data.days[0].items).toEqual([]);
    expect(ids(res.data.days[1].items)).toEqual([morning.id, daily.id, day2.id, day.id, late.id, evening.id]);
    expect(ids(res.data.days[2].items)).toEqual([daily.id]);
    expect(res.data.days[1].items[1]).toEqual({
      choreId: daily.id,
      day: "2026-11-02",
      title: "Cat",
      note: "",
      assignee: null,
      part: "morning",
      time: "08:00",
      repeating: true,
      done: false,
      doneAt: null,
      doneBy: null,
      subscribed: true,
    });
    expect(res.data.days[1].items[0]).toMatchObject({ repeating: false, subscribed: false });
    // Overdue: open single chores before today, oldest first.
    expect(ids(res.data.overdue)).toEqual([older.id, old.id]);
    expect(res.data.overdue[0]).toMatchObject({ day: "2026-10-01", part: "evening", done: false });

    // Today defaults to the server's day (NOW: 2026-11-01).
    expect(ids((await view("GET", "/chores/agenda?from=2026-11-01&to=2026-11-01")).data.overdue)).toEqual([older.id, old.id]);
    // Range checks: both required, to ≥ from, at most 62 days.
    const status = async (q: string) => (await view("GET", `/chores/agenda${q}`)).status;
    expect(await status("?from=2026-11-01")).toBe(400);
    expect(await status("?to=2026-11-01")).toBe(400);
    expect(await status("?from=2026-11-02&to=2026-11-01")).toBe(400);
    expect(await status("?from=2026-11-01&to=2027-01-01")).toBe(200); // 62 days
    expect(await status("?from=2026-11-01&to=2027-01-02")).toBe(400);
    expect(await status("?from=2026-11-01&to=2026-11-01&today=x")).toBe(400);
    expect((await edit("POST", "/chores/agenda", {})).status).toBe(405);
    expect((await call(makeUser(db).id)("GET", "/chores/agenda?from=2026-11-01&to=2026-11-01")).status).toBe(404);
  });

  it("sorts by title on the same day", async () => {
    const edit = call(editorId);
    for (const title of ["b", "C", "a"]) await edit("POST", "/chores", { title, day: "2026-11-05" });
    expect((await edit("GET", "/chores")).data.chores.map((c: { title: string }) => c.title)).toEqual(["a", "b", "C"]);
  });

  it("need a day when repeating; becoming repeating opens a done chore", async () => {
    const edit = call(editorId);
    const { chore } = (await edit("POST", "/chores", { title: "Water plants", day: "2026-10-28" })).data;
    await edit("POST", `/chores/${chore.id}/done`, { done: true });
    const repeating = await edit("PATCH", `/chores/${chore.id}`, { rrule: "FREQ=WEEKLY" });
    expect(repeating.data.chore).toMatchObject({ rrule: "FREQ=WEEKLY", done: false, doneAt: null, next: "2026-11-04" });
    expect((await edit("POST", `/chores/${chore.id}/done`, { done: true })).status).toBe(400);
    // Once again: still open.
    const single = await edit("PATCH", `/chores/${chore.id}`, { rrule: null });
    expect(single.data.chore).toMatchObject({ rrule: null, done: false, next: "2026-10-28" });
  });

  it("keep the id they are put back with", async () => {
    const edit = call(editorId);
    const { chore } = (await edit("POST", "/chores", { title: "Bins", day: "2026-11-02" })).data;
    await edit("DELETE", `/chores/${chore.id}`);
    const back = await edit("POST", "/chores", { id: chore.id, title: "Bins", day: "2026-11-02" });
    expect(back.status).toBe(201);
    expect(back.data.chore.id).toBe(chore.id);
    expect((await edit("POST", "/chores", { id: chore.id, title: "Bins", day: "2026-11-02" })).status).toBe(409);
    expect((await edit("POST", "/chores", { id: "../x", title: "Bins", day: "2026-11-02" })).status).toBe(400);
  });

  it("move to the account of the person who accepts their invite", async () => {
    const { person, invite } = addPerson(db, { id: editorId }, familyId, { name: "Leo", invite: "viewer" }, NOW);
    const edit = call(editorId);
    const { chore } = (await edit("POST", "/chores", { title: "Homework", day: "2026-11-02", assigneeId: person.id })).data;
    const leo = makeUser(db);
    acceptInvite(db, leo.id, invite!.code, NOW);
    expect((await edit("GET", `/chores/${chore.id}`)).data.chore.assignee).toEqual({ id: leo.id, name: "Leo", account: true });
    // The new member may mark it done.
    expect((await call(leo.id)("POST", `/chores/${chore.id}/done`, { done: true })).status).toBe(200);
  });

  it("are nobody's and unsubscribed once their member leaves the family", async () => {
    const edit = call(editorId);
    const { chore } = (await edit("POST", "/chores", { title: "Laundry", day: "2026-11-02", assigneeId: viewerId, subscriberIds: [editorId, viewerId] })).data;
    const other = makeFamily(db, viewerId).id;
    const elsewhere = (await call(viewerId, other)("POST", "/chores", { title: "Laundry", day: "2026-11-02", assigneeId: viewerId })).data.chore;
    removeMember(db, { id: editorId }, familyId, viewerId);
    expect((await edit("GET", `/chores/${chore.id}`)).data.chore).toMatchObject({ assignee: null, subscriberIds: [editorId] });
    // Their chores in other families stay theirs, and so do their subscriptions there.
    expect((await call(viewerId, other)("GET", `/chores/${elsewhere.id}`)).data.chore).toMatchObject({
      assignee: { id: viewerId },
      subscriberIds: [viewerId],
    });
  });

  it("answer 404 when the module is turned off", async () => {
    const edit = call(editorId);
    expect((await edit("GET", "/chores")).status).toBe(200);
    process.env.DISABLED_MODULES = "chores";
    const res = await edit("GET", "/chores");
    expect(res).toEqual({ status: 404, data: { error: "This module is turned off on this server" } });
  });
});
