// GET /api/v1/families/{id}/search (lib/families/search.ts): one search across the modules for
// the app's search tab.

import { randomUUID } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import { createFamilyApi } from "@/lib/api/family-api";
import { handleDisabledModules } from "@/lib/api/disabled-modules";
import { createToken } from "@/lib/auth/tokens";
import {
  apptSearches,
  calEvents,
  calNotes,
  chats,
  familyPeople,
  finCategories,
  finTransactions,
  recipes,
} from "@/lib/db/schema";
import { handleFamilyApp } from "@/lib/families/app-routes";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const BASE = "http://ohana.test/api/v1";

afterEach(() => {
  delete process.env.DISABLED_MODULES;
});

function setup() {
  const db = createTestDb();
  const handler = createFamilyApi([handleDisabledModules, handleFamilyApp], { db, appUrl: "http://ohana.test", now: () => NOW });
  const editor = makeUser(db, { email: "anna@test", name: "Anna Weber" });
  const viewer = makeUser(db, { email: "ben@test", name: "Ben" });
  const outsider = makeUser(db, { email: "eve@test" });
  const family = makeFamily(db, editor.id, [{ userId: viewer.id, role: "viewer" }]);
  const get = async (userId: string, query: string) => {
    const token = createToken(db, { userId, kind: "api" }, NOW).token;
    const res = await handler(
      new Request(`${BASE}/families/${family.id}/search?${query}`, { headers: { authorization: `Bearer ${token}` } }),
    );
    return { status: res.status, data: (await res.json()) as any };
  };
  const familyId = family.id;
  db.insert(recipes)
    .values([
      { id: "r1", familyId, title: "Lasagne", description: "Grandma's, with béchamel", listType: "KNOWN", createdAt: NOW, updatedAt: NOW },
      { id: "r2", familyId, title: "Veggie lasagne", listType: "TO_TRY", createdAt: NOW, updatedAt: NOW },
      { id: "r3", familyId, title: "Soup", description: "Leftover lasagne sheets", listType: "KNOWN", createdAt: NOW, updatedAt: NOW },
    ])
    .run();
  db.insert(calEvents)
    .values([
      { id: "e1", familyId, day: "2026-11-12", start: "09:30", title: "Pediatrician", location: "Dr. Weber, Hauptstr. 1", person: "Mia", createdAt: NOW },
      { id: "e2", familyId, day: "2025-03-02", title: "Dr. Weber", createdAt: NOW },
    ])
    .run();
  db.insert(calNotes)
    .values([
      { familyId, day: "2026-12-24", icon: "🎄", comment: "Lasagne at grandma's\nbring wine" },
      { familyId, day: "2026-12-25", icon: "🎁", comment: "" },
    ])
    .run();
  db.insert(finCategories).values({ familyId, id: "home", name: "Möbel", color: "#888" }).run();
  db.insert(finTransactions)
    .values([
      { familyId, id: randomUUID(), day: "2026-10-03", amountCents: -24999, payee: "IKEA", description: "Shelf", categoryId: "home", createdAt: NOW },
      { familyId, id: randomUUID(), day: "2026-10-04", amountCents: -500, payee: "Bakery", note: "for the ikea trip", createdAt: NOW },
    ])
    .run();
  db.insert(apptSearches)
    .values({ id: "s1", familyId, name: "Dermatologist", specialityLabel: "Hautarzt", locationLabel: "München", createdAt: NOW, updatedAt: NOW })
    .run();
  db.insert(familyPeople).values({ id: "p1", familyId, name: "Mia Müller", createdAt: NOW }).run();
  db.insert(chats)
    .values([
      { id: "c1", familyId, userId: editor.id, title: "Lasagne for Sunday", createdAt: NOW, updatedAt: NOW },
      { id: "c2", familyId, userId: viewer.id, title: "Ben's lasagne chat", createdAt: NOW, updatedAt: NOW },
    ])
    .run();
  return { db, family, editor, viewer, outsider, get };
}

const pick = (results: any[], kind: string) => results.filter((r) => r.kind === kind);

describe("GET /search", () => {
  it("finds recipes, notes and the user's own chats together, title matches first", async () => {
    const s = setup();
    const { status, data } = await s.get(s.editor.id, "q=lasagne");
    expect(status).toBe(200);
    expect(data.query).toBe("lasagne");
    expect(data.currency).toBe("EUR");
    expect(pick(data.results, "recipe").map((r: any) => r.id)).toEqual(["r1", "r2", "r3"]);
    expect(pick(data.results, "note")).toEqual([
      { kind: "note", id: "2026-12-24", title: "🎄 · Lasagne at grandma's", detail: "", day: "2026-12-24" },
    ]);
    expect(pick(data.results, "chat").map((r: any) => r.id)).toEqual(["c1"]);
    // Grouped in the kinds' order.
    expect([...new Set(data.results.map((r: any) => r.kind))]).toEqual(["recipe", "note", "chat"]);
  });

  it("matches every word, ignoring case and accents, in events, people and searches", async () => {
    const s = setup();
    const weber = (await s.get(s.viewer.id, "q=dr%20WEBER")).data.results;
    // The one with both words in its title first; the other has them in its location.
    expect(pick(weber, "event").map((r: any) => [r.id, r.time, r.detail])).toEqual([
      ["e2", null, ""],
      ["e1", "09:30", "Dr. Weber, Hauptstr. 1 · Mia"],
    ]);
    const mia = (await s.get(s.viewer.id, "q=mia%20muller")).data.results;
    expect(pick(mia, "person")).toEqual([{ kind: "person", id: "p1", title: "Mia Müller", detail: "", day: null, account: false }]);
    expect(pick(mia, "event")).toEqual([]);
    const anna = (await s.get(s.viewer.id, "q=weber")).data.results;
    expect(pick(anna, "person")).toMatchObject([{ id: s.editor.id, title: "Anna Weber", detail: "anna@test", account: true }]);
    const muc = (await s.get(s.viewer.id, "q=munchen")).data.results;
    expect(pick(muc, "search")).toEqual([
      { kind: "search", id: "s1", title: "Dermatologist", detail: "Hautarzt · München", day: null },
    ]);
  });

  it("finds transactions by payee, description, note and category", async () => {
    const s = setup();
    const { data } = await s.get(s.editor.id, "q=ikea");
    expect(pick(data.results, "transaction").map((r: any) => [r.title, r.detail, r.day, r.amountCents])).toEqual([
      ["IKEA", "Shelf · Möbel", "2026-10-03", -24999],
      ["Bakery", "", "2026-10-04", -500],
    ]);
    const furniture = (await s.get(s.editor.id, "q=mobel")).data.results;
    expect(pick(furniture, "transaction").map((r: any) => r.title)).toEqual(["IKEA"]);
  });

  it("limits each kind and counts the rest; an empty query finds nothing", async () => {
    const s = setup();
    const { data } = await s.get(s.editor.id, "q=lasagne&limit=1");
    expect(pick(data.results, "recipe").map((r: any) => r.id)).toEqual(["r1"]);
    expect(data.more).toEqual({ recipe: 2 });
    expect((await s.get(s.editor.id, "q=%20%20")).data).toEqual({ query: "", currency: "EUR", results: [], more: {} });
  });

  it("leaves out turned-off modules", async () => {
    const s = setup();
    process.env.DISABLED_MODULES = "meals,finance,assistant,appointments";
    const kinds = async (q: string) => [...new Set((await s.get(s.editor.id, `q=${q}`)).data.results.map((r: any) => r.kind))];
    expect(await kinds("lasagne")).toEqual(["note"]);
    expect(await kinds("ikea")).toEqual([]);
    expect(await kinds("hautarzt")).toEqual([]);
  });

  it("is for members only", async () => {
    const s = setup();
    expect((await s.get(s.outsider.id, "q=lasagne")).status).toBe(404);
  });
});
