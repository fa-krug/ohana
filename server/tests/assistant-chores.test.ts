// The assistant's chore tools (lib/assistant/tools/chores.ts) against the in-memory database:
// listing, adding by a member's name, changing, removing and marking done, and the undo steps
// replayed through the family API.

import { afterEach, describe, expect, it } from "vitest";
import type { NetOptions } from "@/lib/assistant/net";
import { runTool, type ToolContext, TOOLS, toolsFor } from "@/lib/assistant/tools";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { getChoreRow, listChores } from "@/lib/chores/chores";
import { addPerson } from "@/lib/families/people";
import { type AssistantTest, assistantTest } from "@/lib/test/assistant";
import { NOW } from "@/lib/test/factories";

let current: AssistantTest[] = [];
afterEach(async () => {
  await Promise.all(current.map((t) => t.stop()));
  current = [];
  delete process.env.DISABLED_MODULES;
});

const TODAY = "2026-11-02";
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Res = { ok: boolean; result: any; summary: string; change?: any };

function family() {
  const t = assistantTest({ worker: false });
  current.push(t);
  const ctx: ToolContext = {
    lang: "en",
    calendar: new DrizzleCalendarStore(t.db),
    finance: new DrizzleFinanceStore(t.db),
    db: t.db,
    familyId: t.familyId,
    net: {} as NetOptions,
    search: null,
    userId: t.editor.id,
    today: TODAY,
    now: () => NOW,
  };
  const tool = async (name: string, args: unknown): Promise<Res> =>
    (await runTool(name, JSON.stringify(args), ctx, new Set(Object.keys(TOOLS)))) as Res;
  const undo = async (change: { undo: { method: string; path: string; body?: unknown }[] }) => {
    for (const step of change.undo) {
      const res = await t.call(step.method, t.f + step.path, step.body);
      expect(res.status, JSON.stringify(res.data)).toBeLessThan(300);
    }
  };
  const mia = addPerson(t.db, { id: t.editor.id }, t.familyId, { name: "Mia" }, NOW).person;
  return { t, tool, undo, mia };
}

describe("chore tools", () => {
  it("add a chore for a member by name, and undo removes it", async () => {
    const f = family();
    const res = await f.tool("add_chore", { title: "Feed the cat", assignee: "mia", day: "2026-11-03", rrule: "FREQ=DAILY" });
    expect(res.ok, JSON.stringify(res.result)).toBe(true);
    expect(res.result).toMatchObject({
      title: "Feed the cat",
      assignee: { id: f.mia.id, name: "Mia", account: false },
      rrule: "FREQ=DAILY",
      next: "2026-11-03",
    });
    expect(res.change).toEqual({
      kind: "chores",
      summary: "Added the chore “Feed the cat”",
      undo: [{ method: "DELETE", path: `/chores/${res.result.id}` }],
    });
    await f.undo(res.change);
    expect(listChores(f.t.db, f.t.familyId, TODAY)).toEqual([]);
  });

  it("refuse someone who isn't in the family", async () => {
    const f = family();
    const res = await f.tool("add_chore", { title: "Bins", assignee: "Grandpa", day: "2026-11-03" });
    expect(res.ok).toBe(false);
    expect(res.result.error).toMatch(/isn't a member of the family/);
  });

  it("list the chores and the people", async () => {
    const f = family();
    await f.tool("add_chore", { title: "Bins", day: "2026-11-05" });
    const res = await f.tool("get_chores", {});
    expect(res.ok).toBe(true);
    expect(res.result.chores.map((c: { title: string }) => c.title)).toEqual(["Bins"]);
    expect(res.result.people.map((p: { name: string }) => p.name)).toContain("Mia");
  });

  it("change a chore, and undo puts it back (done again too)", async () => {
    const f = family();
    const { result: chore } = await f.tool("add_chore", { title: "Water plants", day: "2026-10-30", assignee: f.mia.id, note: "Balcony" });
    await f.tool("set_chore_done", { id: chore.id, done: true });
    const res = await f.tool("update_chore", { id: chore.id, title: "Water all plants", assignee: null, rrule: "FREQ=WEEKLY" });
    expect(res.ok, JSON.stringify(res.result)).toBe(true);
    expect(res.result).toMatchObject({ title: "Water all plants", assignee: null, rrule: "FREQ=WEEKLY", done: false });
    expect(res.change.undo).toEqual([
      {
        method: "PATCH",
        path: `/chores/${chore.id}`,
        body: { title: "Water plants", note: "Balcony", assigneeId: f.mia.id, day: "2026-10-30", time: null, rrule: null },
      },
      { method: "POST", path: `/chores/${chore.id}/done`, body: { done: true } },
    ]);
    await f.undo(res.change);
    expect(getChoreRow(f.t.db, f.t.familyId, chore.id)).toMatchObject({
      title: "Water plants",
      assigneePersonId: f.mia.id,
      rrule: null,
      doneAt: expect.any(Date),
    });
  });

  it("remove a chore, and undo brings it back with its id", async () => {
    const f = family();
    const { result: chore } = await f.tool("add_chore", { title: "Laundry", day: "2026-11-01", time: "18:00" });
    await f.tool("set_chore_done", { id: chore.id, done: true });
    const res = await f.tool("remove_chore", { id: chore.id });
    expect(res.ok).toBe(true);
    expect(res.change.summary).toBe("Removed the chore “Laundry”");
    expect(getChoreRow(f.t.db, f.t.familyId, chore.id)).toBeNull();
    await f.undo(res.change);
    expect(listChores(f.t.db, f.t.familyId, TODAY)).toEqual([
      expect.objectContaining({ id: chore.id, title: "Laundry", time: "18:00", done: true }),
    ]);
    expect((await f.tool("remove_chore", { id: "nope" })).result.error).toMatch(/No chore/);
  });

  it("mark a single chore done, and undo opens it again; not a repeating one", async () => {
    const f = family();
    const { result: chore } = await f.tool("add_chore", { title: "Tax return", day: "2026-11-15" });
    const res = await f.tool("set_chore_done", { id: chore.id, done: true });
    expect(res.result).toMatchObject({ done: true, next: null });
    expect(res.change.undo).toEqual([{ method: "POST", path: `/chores/${chore.id}/done`, body: { done: false } }]);
    await f.undo(res.change);
    expect(getChoreRow(f.t.db, f.t.familyId, chore.id)?.doneAt).toBeNull();

    const { result: weekly } = await f.tool("add_chore", { title: "Vacuum", day: "2026-11-02", rrule: "FREQ=WEEKLY" });
    expect((await f.tool("set_chore_done", { id: weekly.id, done: true })).ok).toBe(false);
  });

  it("are read-only without writes and gone with the module off", () => {
    const names = (writes: boolean) => toolsFor({ writes, search: false }).map((t) => t.function.name);
    expect(names(true)).toEqual(expect.arrayContaining(["get_chores", "add_chore", "update_chore", "remove_chore", "set_chore_done"]));
    expect(names(false)).toContain("get_chores");
    expect(names(false)).not.toContain("add_chore");
    process.env.DISABLED_MODULES = "chores";
    expect(names(true).some((n) => n.includes("chore"))).toBe(false);
  });
});
