// Chores (/families/{id}/chores…): roles, checks, `next`, done, and what happens to a chore's
// assignee when a person accepts their invite or a member leaves.

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
      rrule: null,
      done: false,
      doneAt: null,
      next: "2026-11-03",
      occurrences: [],
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
    expect(changed.data.chore).toMatchObject({ title: "Bins", note: "Blue one", time: null, assignee: null, day: "2026-11-03" });

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

    const done = await view("POST", `/chores/${mine.id}/done`, { done: true });
    expect(done.status).toBe(200);
    expect(done.data.chore).toMatchObject({ done: true, doneAt: NOW.toISOString(), next: null, updatedAt: NOW.toISOString() });
    const open = await edit("POST", `/chores/${mine.id}/done`, { done: false });
    expect(open.data.chore).toMatchObject({ done: false, doneAt: null, next: "2026-10-30" });
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

  it("list the occurrences around today for repeating ones", async () => {
    const edit = call(editorId);
    const add = async (body: Record<string, unknown>) =>
      (await edit("POST", "/chores?today=2026-11-04", { title: "x", ...body })).data.chore.occurrences;
    // Single: none.
    expect(await add({ day: "2026-11-10" })).toEqual([]);
    // The last before today, today's and the first after it.
    expect(await add({ day: "2026-10-01", rrule: "FREQ=DAILY" })).toEqual(["2026-11-03", "2026-11-04", "2026-11-05"]);
    // None today: the one before and the next.
    expect(await add({ day: "2026-10-05", rrule: "FREQ=WEEKLY;BYDAY=MO" })).toEqual(["2026-11-02", "2026-11-09"]);
    // Not started yet: only the first.
    expect(await add({ day: "2026-12-01", rrule: "FREQ=MONTHLY" })).toEqual(["2026-12-01"]);
    // Ended: only the last one.
    expect(await add({ day: "2026-10-01", rrule: "FREQ=WEEKLY;COUNT=2" })).toEqual(["2026-10-08"]);
  });

  it("sorts by title on the same day", async () => {
    const edit = call(editorId);
    for (const title of ["b", "C", "a"]) await edit("POST", "/chores", { title, day: "2026-11-05" });
    expect((await edit("GET", "/chores")).data.chores.map((c: { title: string }) => c.title)).toEqual(["a", "b", "C"]);
  });

  it("can't be done when repeating; becoming repeating opens a done chore", async () => {
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

  it("are nobody's once their member leaves the family", async () => {
    const edit = call(editorId);
    const { chore } = (await edit("POST", "/chores", { title: "Laundry", day: "2026-11-02", assigneeId: viewerId })).data;
    const other = makeFamily(db, viewerId).id;
    const elsewhere = (await call(viewerId, other)("POST", "/chores", { title: "Laundry", day: "2026-11-02", assigneeId: viewerId })).data.chore;
    removeMember(db, { id: editorId }, familyId, viewerId);
    expect((await edit("GET", `/chores/${chore.id}`)).data.chore.assignee).toBeNull();
    // Their chores in other families stay theirs.
    expect((await call(viewerId, other)("GET", `/chores/${elsewhere.id}`)).data.chore.assignee).toMatchObject({ id: viewerId });
  });

  it("answer 404 when the module is turned off", async () => {
    const edit = call(editorId);
    expect((await edit("GET", "/chores")).status).toBe(200);
    process.env.DISABLED_MODULES = "chores";
    const res = await edit("GET", "/chores");
    expect(res).toEqual({ status: 404, data: { error: "This module is turned off on this server" } });
  });
});
