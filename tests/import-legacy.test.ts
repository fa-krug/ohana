import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { and, eq } from "drizzle-orm";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import {
  aiSettings,
  apptIgnored,
  apptRuns,
  apptSearchChannels,
  apptSearches,
  authTokens,
  calEntries,
  calEntryTypes,
  calNotes,
  chatItems,
  chatMessages,
  chats,
  cookingSteps,
  families,
  familyMembers,
  finAccounts,
  finCategories,
  finSettings,
  finTransactions,
  ingredients,
  invites,
  mealPlanEntries,
  mealPlanExcludedTags,
  mealPlans,
  mealTags,
  notificationChannels,
  recipeIngredients,
  recipes,
  recipeTags,
  shoppingListItems,
  stepIngredients,
  units,
  users,
} from "@/lib/db/schema";
import { verifyPassword } from "@/lib/auth/password";
import { findToken } from "@/lib/auth/tokens";
import { openCookless } from "@/lib/import/cookless/accounts";
import { loadFamilyPlannerDump } from "@/lib/import/family-planner/source";
import { openFma } from "@/lib/import/fma/accounts";
import { ImportRefused, runImport, type ImportSources } from "@/lib/import";
import { formatReport } from "@/lib/import/report";
import { categoryTree } from "@/lib/finance/category-tree";
import { defaultCategories, financeSummary, findTransactions, listAccounts, publicTransaction } from "@/lib/finance/finance";
import { DrizzleFinanceStore } from "@/lib/finance/store";
import { DEFAULT_TAGS } from "@/lib/meals/recipes/tag-defaults";
import { SecretBox, devSecret } from "@/lib/secrets";
import { Runner } from "@/lib/assistant/chats";
import { DrizzleAssistantStore } from "@/lib/assistant/store";
import { GEMINI_BASE_URL } from "@/lib/import/cookless/assistant";
import Database from "better-sqlite3";
import { copyFileSync } from "node:fs";
import { createTestDb } from "@/lib/test/db";
import { makeUser } from "@/lib/test/factories";
import { CK, FMA, FP, FP_DUMP, MAP, makeCooklessDb, makeFmaDb } from "@/lib/test/legacy";

const NOW = new Date("2026-11-01T12:00:00Z");
const DEFAULT_TAG_COUNT = Object.values(DEFAULT_TAGS).flat().length;

let dir: string;
let cookless: { path: string; mediaDir: string };
let fmaPath: string;

beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), "ohana-import-"));
  cookless = await makeCooklessDb(dir, Math.floor(NOW.getTime() / 1000));
  fmaPath = await makeFmaDb(dir);
});
afterAll(() => rmSync(dir, { recursive: true, force: true }));

let db: Db;
let mediaRoot: string;
let secrets: SecretBox;
let sources: ImportSources;

/** An Ohana database as after `npm run db:migrate`: seeded units and ingredients (other ids). */
function target(): Db {
  const t = createTestDb();
  t.insert(ingredients).values([{ nameEn: "Salt", nameDe: "Salz" }, { nameEn: "tomato", nameDe: "Tomate", category: "PRODUCE" }]).run();
  t.insert(units).values([{ nameEn: "piece", nameDe: "Stück", abbreviation: "pc" }, { nameEn: "gram", nameDe: "Gramm", abbreviation: "g" }]).run();
  return t;
}

function allSources(): ImportSources {
  return {
    familyPlanner: loadFamilyPlannerDump(FP_DUMP),
    cookless: openCookless(cookless.path, cookless.mediaDir),
    fma: openFma(fmaPath),
  };
}

beforeEach(() => {
  db = target();
  mediaRoot = mkdtempSync(join(dir, "media-root-"));
  secrets = new SecretBox(devSecret());
  sources = allSources();
});

const run = (opts: { dryRun?: boolean; force?: boolean; familyPlannerAiSecret?: string } = {}, s: ImportSources = sources) =>
  runImport(db, s, { map: MAP, now: NOW, secrets, mediaRoot, ...opts });

const user = (email: string) => db.select().from(users).where(eq(users.email, email)).get();
const role = (familyId: string, email: string) =>
  db
    .select({ role: familyMembers.role })
    .from(familyMembers)
    .where(and(eq(familyMembers.familyId, familyId), eq(familyMembers.userId, user(email)!.id)))
    .get()?.role;

describe("legacy import: accounts and families", () => {
  it("merges users by lowercased email, with name, admin flag and password by precedence", async () => {
    const report = await run();
    const emails = db.select({ email: users.email }).from(users).all().map((u) => u.email).sort();
    expect(emails).toEqual(["admin", "anna@example.com", "ben@example.com", "carl@example.com", "erik@example.com"]);

    const anna = user("anna@example.com")!;
    expect(anna.id).toBe(FP.anna); // family-planner's id
    expect(anna.name).toBe("Anna Krug");
    expect(anna.isAdmin).toBe(true); // findmyappointment is_staff
    expect(anna.preferredLanguage).toBe("de");
    expect(anna.onboardingStep).toBe("ADD_PASSKEY");
    expect(await verifyPassword(anna.password, FP.annaPassword)).toBe(true); // family-planner's hash wins
    expect(anna.createdAt.getTime()).toBe((1_700_000_000 - 86_400 * 500) * 1000); // the earliest
    expect(anna.lastFamilyId).toBe(FP.krug); // cookless's active household, mapped

    // Ben has no password in family-planner (passkey only): cookless's.
    const ben = user("ben@example.com")!;
    expect(ben.name).toBe("Ben");
    expect(await verifyPassword(ben.password, CK.benPassword)).toBe(true);

    // admin/admin (must change), cookless's never-changed initial password, the Django
    // import's "password": not carried over; they need a setup link.
    for (const email of ["admin", "carl@example.com", "erik@example.com"]) {
      expect(user(email)!.password).toBe("");
      expect(user(email)!.onboardingStep).toBe("SET_CREDENTIALS");
    }
    expect(user("admin")!.isAdmin).toBe(true);
    expect(report.users.filter((u) => u.needsSetupLink).map((u) => u.email).sort()).toEqual([
      "admin",
      "carl@example.com",
      "erik@example.com",
    ]);
    expect(formatReport(report)).toContain("npm run setup-link -- carl@example.com");

    // Deactivated cookless accounts stay behind.
    expect(user("dora@example.com")).toBeUndefined();
    expect(report.skipped).toContainEqual(expect.objectContaining({ source: "cookless", key: "dora@example.com", reason: "deactivated" }));
  });

  it("maps households to families and combines members (editor wins)", async () => {
    const report = await run();
    const fams = db.select().from(families).all();
    expect(fams.map((f) => f.id).sort()).toEqual([CK.carl, FMA.erik, FP.oma, FP.krug].sort());

    const krug = fams.find((f) => f.id === FP.krug)!;
    expect(krug).toMatchObject({
      name: "Krug",
      feedId: "feedKrug000000000001",
      legacyId: "legacyKrug0000000001",
      homeAddress: "Hauptstraße 1, Berlin",
      homeLat: 52.52,
      homeLng: 13.405,
    });
    expect(krug.createdAt.toISOString()).toBe("2024-05-01T10:00:00.000Z"); // timestamps are seconds

    expect(role(FP.krug, "anna@example.com")).toBe("editor");
    expect(role(FP.krug, "ben@example.com")).toBe("editor"); // viewer in family-planner, MEMBER in cookless
    expect(role(FP.oma, "ben@example.com")).toBe("viewer");
    expect(role(FP.oma, "admin")).toBe("editor");
    expect(role(CK.carl, "carl@example.com")).toBe("editor"); // OWNER
    expect(role(FMA.erik, "erik@example.com")).toBe("editor");
    expect(db.select().from(familyMembers).where(eq(familyMembers.familyId, FP.krug)).all()).toHaveLength(2);

    const unmapped = fams.find((f) => f.id === CK.carl)!;
    expect(unmapped.name).toBe("Carls Küche");
    expect(unmapped.feedId).toMatch(/^[A-Za-z0-9]{20}$/);
    expect(unmapped.legacyId).toBeNull();
    expect(report.families.find((f) => f.id === FP.krug)!.from).toEqual({ familyPlanner: FP.krug, cookless: CK.krug, fma: FMA.krug });
  });

  it("imports family-planner's API tokens as they are, not sessions, setup links or passkeys", async () => {
    const report = await run();
    const found = findToken(db, FP.apiToken, "api", NOW);
    expect(found?.user.email).toBe("anna@example.com");
    expect(found?.token.name).toBe("Home Assistant");
    expect(db.select().from(authTokens).all()).toHaveLength(1);
    const reasons = report.skipped.filter((s) => s.table === "auth_tokens" || s.table.startsWith("passkey")).map((s) => s.source);
    expect(reasons.sort()).toEqual(["cookless", "familyPlanner", "familyPlanner", "familyPlanner"]);
  });

  it("keeps open invites only", async () => {
    const report = await run();
    expect(db.select().from(invites).all()).toEqual([
      expect.objectContaining({ code: "OPENCODE", familyId: FP.krug, role: "editor", createdById: FP.anna }),
    ]);
    expect(report.skipped.filter((s) => s.table === "invites").map((s) => s.reason).sort()).toEqual(["already used", "expired"]);
  });

  it("validates the import map", async () => {
    await expect(
      runImport(db, sources, { map: { families: [{ cookless: "nope" }] }, now: NOW, secrets, mediaRoot }),
    ).rejects.toThrow(/cookless has no household nope/);
    await expect(
      runImport(db, sources, { map: { families: [{ fma: FMA.krug }, { fma: FMA.krug }] }, now: NOW, secrets, mediaRoot }),
    ).rejects.toThrow(/mapped twice/);
    await expect(
      runImport(db, sources, { map: { ...MAP, skip: [{ fma: FMA.krug }] }, now: NOW, secrets, mediaRoot }),
    ).rejects.toThrow(/mapped twice/);
    await expect(
      runImport(db, sources, { map: { ...MAP, skip: [{ familyPlanner: "nope" }] }, now: NOW, secrets, mediaRoot }),
    ).rejects.toThrow(/family-planner has no family nope/);
    expect(db.select().from(users).all()).toHaveLength(0);
  });

  it("leaves out the families the map skips", async () => {
    const report = await runImport(db, sources, { map: { ...MAP, skip: [{ familyPlanner: FP.oma }] }, now: NOW, secrets, mediaRoot });
    expect(db.select().from(families).where(eq(families.id, FP.oma)).all()).toHaveLength(0);
    expect(db.select().from(calEntries).where(eq(calEntries.familyId, FP.oma)).all()).toHaveLength(0);
    expect(report.families.map((f) => f.id)).not.toContain(FP.oma);
    expect(report.skipped.some((s) => s.reason === "its family isn't imported")).toBe(true);
    expect(db.select().from(families).where(eq(families.id, FP.krug)).all()).toHaveLength(1);
  });
});

describe("legacy import: modules", () => {
  it("imports the calendar; families without one get the presets", async () => {
    await run();
    const types = db.select().from(calEntryTypes).where(eq(calEntryTypes.familyId, FP.krug)).all();
    expect(types.map((t) => `${t.year}/${t.id}/${t.role}`).sort()).toEqual([
      "2025/vacation/covers",
      "2026/holiday/day_off",
      "2026/kita/needs_cover",
      "2026/vacation/covers",
    ]);
    expect(db.select().from(calEntries).where(eq(calEntries.familyId, FP.krug)).all()).toHaveLength(4);
    expect(db.select().from(calEntries).where(eq(calEntries.familyId, FP.oma)).all()).toEqual([
      { familyId: FP.oma, day: "2026-03-03", year: 2026, typeId: "sick" },
    ]);
    const notes = db.select().from(calNotes).where(eq(calNotes.familyId, FP.krug)).all();
    expect(notes.find((n) => n.day === "2026-12-24")).toMatchObject({ icon: "🎄", comment: "Heiligabend\tbei Oma\nab 15 Uhr" });

    // family-planner's families keep their calendar exactly; the others get the preset types
    // (no duplicates), in the household's language.
    expect(db.select().from(calEntryTypes).where(eq(calEntryTypes.familyId, FP.oma)).all()).toHaveLength(1);
    const erik = db.select().from(calEntryTypes).where(eq(calEntryTypes.familyId, FMA.erik)).all();
    expect(erik.map((t) => t.id).sort()).toEqual(["holiday", "sick", "vacation"]);
    expect(erik.every((t) => t.year === 2026)).toBe(true);
    expect(erik.find((t) => t.id === "vacation")!.name).toBe("Urlaub");
    expect(db.select().from(calEntryTypes).where(eq(calEntryTypes.familyId, CK.carl)).all()).toHaveLength(3);
  });

  it("imports meals with mapped ingredients and units, and copies the photos", async () => {
    const report = await run();
    const krugRecipes = db.select().from(recipes).where(eq(recipes.familyId, FP.krug)).all();
    expect(krugRecipes.map((r) => r.title).sort()).toEqual(["Pasta", "Salat"]);
    const pasta = krugRecipes.find((r) => r.id === CK.pasta)!;
    expect(pasta).toMatchObject({ defaultServings: 4, prepTimeMinutes: 10, cookTimeMinutes: null, image: CK.pastaImage });
    expect(readFileSync(join(mediaRoot, CK.pastaImage), "utf8")).toBe("RIFF-fake-webp-pasta");
    expect(krugRecipes.find((r) => r.id === CK.salad)!.image).toBe(""); // its file is missing
    expect(report.media).toEqual({ copied: 1, missing: ["recipes/missing.webp (file not found)"] });

    // Ingredients and units: matched by name / abbreviation, or added.
    const ri = db
      .select({ ing: ingredients.nameEn, unit: units.abbreviation, base: units.baseUnitId, qty: recipeIngredients.quantity, id: recipeIngredients.id })
      .from(recipeIngredients)
      .innerJoin(ingredients, eq(ingredients.id, recipeIngredients.ingredientId))
      .innerJoin(units, eq(units.id, recipeIngredients.unitId))
      .where(eq(recipeIngredients.recipeId, CK.pasta))
      .orderBy(recipeIngredients.order)
      .all();
    expect(ri.map((r) => [r.ing, r.unit, r.qty])).toEqual([
      ["tomato", "g", "250"],
      ["Dragonfruit", "kg", "0.5"],
    ]);
    const gram = db.select().from(units).where(eq(units.abbreviation, "g")).get()!;
    expect(ri[1].base).toBe(gram.id);
    expect(db.select().from(ingredients).all()).toHaveLength(3);

    const step = db.select().from(cookingSteps).where(eq(cookingSteps.recipeId, CK.pasta)).get()!;
    expect(step).toMatchObject({ method: "MACHINE", turbo: true, speed: 5, durationSeconds: 300 });
    expect(db.select().from(stepIngredients).all()).toEqual([
      expect.objectContaining({ stepId: step.id, recipeIngredientId: ri[0].id, quantity: "250" }),
    ]);

    // Tags: cookless's, and no defaults for that family; the others get the defaults.
    const krugTags = db.select().from(mealTags).where(eq(mealTags.familyId, FP.krug)).all();
    expect(krugTags.map((t) => t.nameEn).sort()).toEqual(["Italian", "Vegetarian"]);
    expect(db.select().from(recipeTags).all()).toEqual([expect.objectContaining({ recipeId: CK.pasta, tagId: CK.vegetarian })]);
    for (const f of [FP.oma, CK.carl, FMA.erik]) {
      expect(db.select().from(mealTags).where(eq(mealTags.familyId, f)).all()).toHaveLength(DEFAULT_TAG_COUNT);
    }
    expect(db.select().from(recipes).where(eq(recipes.familyId, CK.carl)).all().map((r) => r.title)).toEqual(["Suppe"]);

    // The plan.
    expect(db.select().from(mealPlans).where(eq(mealPlans.familyId, FP.krug)).get()).toMatchObject({ id: CK.plan, servings: 3, knownRatio: "0.6" });
    expect(db.select().from(mealPlanExcludedTags).all()).toEqual([expect.objectContaining({ mealPlanId: CK.plan, tagId: CK.italian })]);
    const leftover = db.select().from(mealPlanEntries).where(eq(mealPlanEntries.id, CK.leftover)).get()!;
    expect(leftover).toMatchObject({ isLeftover: true, sourceEntryId: CK.entry });
    expect(db.select().from(shoppingListItems).get()).toMatchObject({ id: CK.item, isChecked: true, quantity: "1" });
  });

  it("imports searches, channels (tokens sealed) and ignore lists, but no run history", async () => {
    const report = await run();
    const channels = db.select().from(notificationChannels).all();
    expect(channels).toHaveLength(2);
    const push = channels.find((c) => c.id === FMA.pushover)!;
    expect(push).toMatchObject({ familyId: FP.krug, provider: "PUSHOVER", target: "user-key", enabled: true });
    expect(push.token).toMatch(/^v1:/);
    expect(push.token).not.toContain("pushover-secret");
    expect(secrets.open(push.token)).toBe("pushover-secret");
    const mail = channels.find((c) => c.id === FMA.email)!;
    expect(mail).toMatchObject({ smtpHost: "smtp.example.com", smtpPort: 587, smtpFrom: "fma@example.com", enabled: false });
    expect(secrets.open(mail.token)).toBe("smtp-password");

    const derm = db.select().from(apptSearches).where(eq(apptSearches.id, FMA.derm)).get()!;
    expect(derm).toMatchObject({
      familyId: FP.krug,
      sources: "both",
      jamedaVideo: "hide",
      jamedaKidsFriendly: true,
      dayLimit: 21,
      scheduleMinutes: 45,
      notifyOnlyEarlier: true,
      lockedUntil: null,
      runRequestedAt: null,
    });
    expect(derm.earliestSeen?.getTime()).toBe((1_700_000_000 + 86_400 * 30) * 1000);
    expect(db.select().from(apptSearches).where(eq(apptSearches.id, FMA.dentist)).get()).toMatchObject({ familyId: FMA.erik, enabled: false, nextRunAt: null });
    expect(db.select().from(apptSearchChannels).all()).toEqual([{ searchId: FMA.derm, channelId: FMA.pushover }]);
    expect(db.select().from(apptIgnored).all()).toEqual([
      expect.objectContaining({ searchId: FMA.derm, providerSlug: "dr-x", source: "jameda", motiveId: 42 }),
    ]);
    expect(db.select().from(apptRuns).all()).toHaveLength(0);
    expect(report.skipped).toContainEqual(expect.objectContaining({ source: "fma", table: "search_runs" }));
  });

  it("imports the finances as they were; families without categories get the defaults", async () => {
    await run();
    const store = new DrizzleFinanceStore(db);
    const tx = (n: number) => `aaaaaaaa-0000-4000-8000-00000000000${n}`;

    // Settings: currency, the CSV mappings and the statistic average (JSON) come back as saved.
    const krug = await store.getFinanceSettings(FP.krug);
    expect(krug?.currency).toBe("EUR");
    expect(krug?.csv_mappings).toEqual([
      expect.objectContaining({ delimiter: ";", skipRows: 4, accountId: "giro", description: [3], signature: "Buchungstag;Wertstellung;Empfänger;Verwendungszweck;Betrag" }),
    ]);
    expect(krug?.benchmark).toEqual({
      label: "Destatis 2023",
      income: { lowCents: 400000, highCents: 500000 },
      expense: { lowCents: 350000, highCents: 350000 },
      categories: [{ categoryId: "food", lowCents: 50000, highCents: 60000 }],
    });
    expect(await store.getFinanceSettings(FP.oma)).toEqual({ family_id: FP.oma, currency: "CHF", csv_mappings: [], benchmark: null, groceries_category_id: null });

    // The category tree, three levels, ids kept; no default categories next to it.
    const cats = await store.listCategories(FP.krug);
    expect(cats.map((c) => c.id).sort()).toEqual(["bakery", "food", "groceries", "household", "salary"]);
    const tree = categoryTree(cats);
    expect(tree.path("bakery")).toBe("Essen > Lebensmittel > Bäckerei");
    expect(tree.depth("bakery")).toBe(3);
    expect(cats.find((c) => c.id === "salary")).toMatchObject({ kind: "income", position: 1, parent_id: null, icon: "💼" });

    // Accounts with their balances: opening + transactions, parts of a split booking not
    // counted (their booking is).
    expect((await listAccounts(store, FP.krug)).map((a) => [a.id, a.openingCents, a.balanceCents])).toEqual([
      ["giro", 100000, 100000 + 300000 - 50000 - 8000],
      ["savings", 500000, 550000],
    ]);

    // Transactions: ids, transfer id, booking, import hash, escapes and created_at (ms) kept.
    const rows = db.select().from(finTransactions).where(eq(finTransactions.familyId, FP.krug)).all();
    expect(rows).toHaveLength(6);
    const byId = new Map(rows.map((r) => [r.id, r]));
    expect(byId.get(tx(1))).toMatchObject({ day: "2026-09-30", amountCents: 300000, categoryId: "salary", accountId: "giro", importHash: "dkb:2026-09-30:300000:arbeitgeber" });
    expect(byId.get(tx(1))!.createdAt.toISOString()).toBe("2026-10-01T08:00:00.123Z");
    expect(byId.get(tx(2))!.transferId).toBe("bbbbbbbb-0000-4000-8000-000000000001");
    expect(byId.get(tx(3))).toMatchObject({ transferId: "bbbbbbbb-0000-4000-8000-000000000001", accountId: "savings", categoryId: null });
    expect(byId.get(tx(5))).toMatchObject({ splitOf: tx(4), categoryId: "bakery", note: "für\tSonntag\nund Montag" });
    expect(byId.get(tx(6))!.splitOf).toBe(tx(4));
    expect(await store.existingImportHashes(FP.krug, ["dkb:2026-09-30:300000:arbeitgeber", "other"])).toEqual(
      new Set(["dkb:2026-09-30:300000:arbeitgeber"]),
    );

    // The list shows the transfer as a pair and the booking with its parts.
    const { rows: listed, links, incomeCents, expenseCents } = await findTransactions(store, FP.krug, new URLSearchParams());
    const items = listed.map((t) => publicTransaction(t, links));
    expect(items.map((t) => t.id)).toEqual([tx(4), tx(5), tx(6), tx(2), tx(3), tx(1)]); // newest day first, then as created
    expect(items.find((t) => t.id === tx(3))!.transferId).toBe("bbbbbbbb-0000-4000-8000-000000000001");
    expect(items.find((t) => t.id === tx(4))!.split).toEqual({ parts: 2, remainderCents: -3000 });
    expect({ incomeCents, expenseCents }).toEqual({ incomeCents: 300000, expenseCents: 8000 });

    // The summary counts the transfer once (net 0) and the booking by its parts and remainder.
    const summary = await financeSummary(store, FP.krug);
    expect(summary).toMatchObject({ currency: "EUR", incomeCents: 300000, expenseCents: 8000 });
    const byCat = new Map(summary.categories.map((c) => [c.categoryId, c]));
    expect(byCat.get("bakery")?.expenseCents).toBe(3000);
    expect(byCat.get("groceries")?.expenseCents).toBe(2000);
    expect(byCat.get("household")?.expenseCents).toBe(3000);
    expect(byCat.get("salary")?.incomeCents).toBe(300000);

    // Families without family-planner categories get the defaults, in their language (Oma's
    // settings came over, its categories are the defaults).
    const defaults = (familyId: string, lang: "en" | "de") =>
      defaultCategories(familyId, lang).map((c) => `${c.id}:${c.name}`).sort();
    const names = (familyId: string) =>
      db.select().from(finCategories).where(eq(finCategories.familyId, familyId)).all().map((c) => `${c.id}:${c.name}`).sort();
    expect(names(FP.oma)).toEqual(defaults(FP.oma, "en"));
    expect(names(FMA.erik)).toEqual(defaults(FMA.erik, "de")); // findmyappointment's household language
    expect(names(CK.carl)).toEqual(defaults(CK.carl, "en"));
    expect(db.select().from(finAccounts).where(eq(finAccounts.familyId, FP.oma)).all()).toHaveLength(0);
    expect(db.select().from(finSettings).all()).toHaveLength(2);
  });

  it("clears finance references to rows that aren't there, and reports them", async () => {
    const s = allSources();
    const t = s.familyPlanner!.tables;
    t.get("finance_categories")!.push({ family_id: FP.krug, id: "orphan", name: "Waise", color: "#000000", icon: "", kind: "nope", position: "9", parent_id: "gone" });
    t.get("transactions")!.push({
      family_id: FP.krug, id: "cccccccc-0000-4000-8000-000000000001", day: "2026-10-07", amount_cents: "-100", payee: "", description: "",
      category_id: "gone", note: "", import_hash: null, created_at: "2026-10-07 10:00:00+00", account_id: "gone", transfer_id: null,
      split_of: "cccccccc-0000-4000-8000-00000000dead",
    });
    const report = await run({}, s);
    expect(db.select().from(finCategories).where(and(eq(finCategories.familyId, FP.krug), eq(finCategories.id, "orphan"))).get())
      .toMatchObject({ parentId: null, kind: "expense" });
    expect(db.select().from(finTransactions).where(eq(finTransactions.id, "cccccccc-0000-4000-8000-000000000001")).get())
      .toMatchObject({ categoryId: null, accountId: null, splitOf: null, amountCents: -100 });
    expect(report.skipped.filter((r) => r.table === "finance_categories" || r.table === "transactions")).toHaveLength(4);
  });

  it("reports the counts, the AI keys to enter again, and no family-planner table left out", async () => {
    const report = await run({ dryRun: true });
    expect(report.counts).toMatchObject({ users: 5, families: 4, family_members: 6, recipes: 3, appt_searches: 2, cal_notes: 2 });
    expect(report.counts).toMatchObject({ fin_settings: 2, fin_accounts: 2, fin_transactions: 6 });
    // Krug's five categories and the defaults of the three other families.
    expect(report.counts.fin_categories).toBe(5 + 3 * defaultCategories("x", "en").length);
    expect(formatReport(report)).toMatch(/fin_transactions\s+6/);
    // Krug's and Oma's from family-planner, Carl's from cookless.
    expect(report.counts).toMatchObject({ ai_settings: 3, chats: 2, chat_items: 5, chat_messages: 5 });
    const text = formatReport(report);
    expect(text).toMatch(/chat_messages\s+5/);
    expect(text).toContain("AI keys to enter again");
    expect(report.aiKeys.map((k) => k.familyId).sort()).toEqual([FP.krug, FP.oma].sort());
    const notes = report.notes.join("\n");
    expect(notes).not.toContain("tables not imported");
    expect(notes).not.toContain("rate_limits");
  });

  it("works with one source alone", async () => {
    const report = await run({}, { fma: openFma(fmaPath) });
    expect(report.counts.families).toBe(2);
    expect(db.select().from(families).all().map((f) => f.id).sort()).toEqual([FMA.erik, FMA.krug].sort());
    expect(report.notes.some((n) => n.includes("no family-planner source was given"))).toBe(true);
  });
});

describe("legacy import: the assistant", () => {
  const settings = (familyId: string) => db.select().from(aiSettings).where(eq(aiSettings.familyId, familyId)).get();

  it("opens family-planner's AI keys with its secret and seals them with Ohana's", async () => {
    // The fixture's keys are sealed with family-planner's SecretBox under FP.aiSecret.
    const old = new SecretBox(FP.aiSecret);
    const report = await run({ familyPlannerAiSecret: FP.aiSecret });
    const krug = settings(FP.krug)!;
    expect(krug).toMatchObject({
      baseUrl: "https://api.openai.com/v1",
      model: "gpt-4o-mini",
      searchProvider: "tavily",
      allowWrites: false,
      contextWindow: 64000,
      imageModel: "",
    });
    expect(krug.updatedAt.toISOString()).toBe("2026-10-01T07:00:00.000Z");
    expect(secrets.open(krug.apiKeyEnc)).toBe(FP.krugApiKey);
    expect(secrets.open(krug.searchKeyEnc)).toBe(FP.krugSearchKey);
    expect(() => old.open(krug.apiKeyEnc)).toThrow(); // sealed again, with Ohana's key
    // Oma's key was sealed with another secret: the settings come without it, reported.
    expect(settings(FP.oma)).toMatchObject({ model: "mistral-small", apiKeyEnc: "", allowWrites: true });
    expect(report.aiKeys).toEqual([
      { familyId: FP.oma, family: "Oma & Opa", keys: ["API key"], reason: "didn't open with the given --family-planner-ai-secret" },
    ]);
    expect(formatReport(report)).toMatch(/AI keys to enter again[^]*"Oma & Opa".*API key/);
  });

  it("without the secret, imports the settings without keys and lists the families", async () => {
    const report = await run();
    expect(settings(FP.krug)).toMatchObject({ model: "gpt-4o-mini", apiKeyEnc: "", searchKeyEnc: "", searchProvider: "tavily" });
    expect(report.aiKeys.find((k) => k.familyId === FP.krug)).toMatchObject({
      keys: ["API key", "search key"],
      reason: "no --family-planner-ai-secret given",
    });
    expect(report.aiKeys.find((k) => k.familyId === FP.oma)).toMatchObject({ keys: ["API key"] });
  });

  it("refuses a malformed secret, and says when no key opened with it", async () => {
    await expect(run({ familyPlannerAiSecret: "short" })).rejects.toBeInstanceOf(ImportRefused);
    const report = await run({ familyPlannerAiSecret: devSecret() });
    expect(report.aiKeys).toHaveLength(2);
    expect(report.notes.join("\n")).toContain("None of family-planner's AI keys opened");
  });

  it("turns cookless's Gemini key into AI settings, unless family-planner has some (they win)", async () => {
    const report = await run({ familyPlannerAiSecret: FP.aiSecret });
    const carl = settings(CK.carl)!;
    expect(carl).toMatchObject({
      baseUrl: GEMINI_BASE_URL,
      model: "gemini-2.5-flash",
      imageModel: "gemini-2.5-flash-image",
      searchProvider: "none",
      searchKeyEnc: "",
      allowWrites: false,
      contextWindow: 0,
    });
    expect(carl.baseUrl).toBe("https://generativelanguage.googleapis.com/v1beta/openai/");
    expect(secrets.open(carl.apiKeyEnc)).toBe(CK.carlGeminiKey);
    // Krug has a Gemini key in cookless too, but family-planner's settings win.
    expect(settings(FP.krug)!.model).toBe("gpt-4o-mini");
    expect(report.skipped).toContainEqual(expect.objectContaining({
      source: "cookless",
      table: "households.gemini_api_key",
      reason: "the family has family-planner's AI settings (they win)",
    }));
    // Without family-planner, Krug gets its Gemini key.
    db = target();
    await run({}, { cookless: openCookless(cookless.path, cookless.mediaDir) });
    expect(secrets.open(settings(CK.krug)!.apiKeyEnc)).toBe("AIzaFakeGeminiKey");
  });

  it("skips a Gemini key when AI was turned off in cookless", async () => {
    const copy = join(dir, "cookless-ai-off.db");
    copyFileSync(cookless.path, copy);
    const w = new Database(copy);
    w.prepare("UPDATE households SET ai_enabled = 0").run();
    w.close();
    const report = await run({}, { cookless: openCookless(copy, cookless.mediaDir) });
    expect(db.select().from(aiSettings).all()).toEqual([]);
    expect(report.skipped.filter((r) => r.table === "households.gemini_api_key")).toHaveLength(2);
  });

  it("imports the chats with their items and messages", async () => {
    await run();
    const idle = db.select().from(chats).where(eq(chats.id, FP.idleChat)).get()!;
    expect(idle).toMatchObject({
      familyId: FP.krug,
      userId: FP.anna,
      title: "Urlaub planen",
      status: "idle",
      runToken: null,
      stop: false,
      rev: 3,
      queue: "[]",
      activity: null,
    });
    expect(idle.createdAt.getTime()).toBe(Date.parse("2026-10-01T07:00:00.123Z")); // milliseconds kept
    expect(idle.updatedAt.getTime()).toBe(Date.parse("2026-10-01T07:01:30.456Z"));
    expect(JSON.parse(idle.context)).toEqual({ day: "2026-10-01", lang: "de", page: "calendar", year: 2026 });
    expect(JSON.parse(idle.notes)).toEqual(["Undid: vacation on 2026-08-03"]);
    expect(JSON.parse(idle.usage!)).toEqual({ max: 128000, used: 2100 });

    // What the app reads through the assistant's store.
    const store = new DrizzleAssistantStore(db);
    expect((await store.listChats(FP.krug, FP.anna)).map((c) => c.id)).toEqual([FP.idleChat]);
    const items = await store.listChatItems(FP.idleChat);
    expect(items.map((i) => [i.seq, i.rev, i.item.kind])).toEqual([[0, 1, "user"], [1, 2, "tool"], [2, 3, "assistant"]]);
    expect(await store.listChatItems(FP.idleChat, 2)).toHaveLength(1);
    const messages = await store.listChatMessages(FP.idleChat);
    expect(messages.map((m) => m.message.role)).toEqual(["user", "assistant", "tool", "assistant"]);
    expect(db.select().from(chatItems).all()).toHaveLength(5);
    expect(db.select().from(chatMessages).all()).toHaveLength(5);
  });

  it("ends a turn that was running as stopped, without calling the model, and drops waiting messages", async () => {
    const report = await run();
    const running = db.select().from(chats).where(eq(chats.id, FP.runningChat)).get()!;
    expect(running).toMatchObject({ status: "running", runToken: null, runUntil: null, stop: true, retries: 0, activity: null, queue: "[]" });
    const notes = report.notes.join("\n");
    expect(notes).toContain(`${FP.runningChat}) in family Oma & Opa was running`);
    expect(notes).toContain("1 waiting message(s) dropped");

    // The worker takes it (nobody holds it) and ends it the way a stop does.
    const store = new DrizzleAssistantStore(db);
    expect(store.pendingChats(NOW).map((c) => c.id)).toEqual([FP.runningChat]);
    const never = () => {
      throw new Error("no model call expected");
    };
    expect(store.claimChatNow(FP.runningChat, "tok", new Date(Date.now() + 30_000).toISOString(), "resume")).not.toBeNull();
    await new Runner({ store, prepare: never, family: never }, FP.runningChat, "tok").drive(false);
    const after = (await store.getChat(FP.runningChat))!;
    expect(after).toMatchObject({ status: "idle", run_token: null, stop: false });
    const items = await store.listChatItems(FP.runningChat);
    expect(items[1].item).toMatchObject({ kind: "tool", status: "error", interrupted: true });
    const messages = (await store.listChatMessages(FP.runningChat)).map((m) => m.message);
    expect(messages.at(-1)).toEqual({ role: "assistant", content: "(stopped)" });
    expect(store.pendingChats(NOW)).toEqual([]);
  });

  it("skips chats whose family or user isn't imported", async () => {
    const s = allSources();
    s.familyPlanner!.tables.get("ai_chats")!.push({
      ...s.familyPlanner!.tables.get("ai_chats")![0],
      id: "fpChatOrphan00000003",
      user_id: "fpUserGone000000009",
    });
    s.familyPlanner!.tables.get("ai_chat_items")!.push({ chat_id: "fpChatOrphan00000003", seq: "0", rev: "1", item: "{}" });
    const report = await run({}, s);
    expect(db.select().from(chats).where(eq(chats.id, "fpChatOrphan00000003")).get()).toBeUndefined();
    expect(report.skipped).toContainEqual(expect.objectContaining({ table: "ai_chats", reason: "its user isn't imported" }));
  });
});

describe("legacy import: safety", () => {
  const tableRows = () => ({
    users: db.select().from(users).all().length,
    families: db.select().from(families).all().length,
    recipes: db.select().from(recipes).all().length,
    ingredients: db.select().from(ingredients).all().length,
  });

  it("a dry run reports everything and writes nothing", async () => {
    const before = tableRows();
    const report = await run({ dryRun: true });
    expect(report.dryRun).toBe(true);
    expect(report.counts).toMatchObject({ users: 5, families: 4, recipes: 3 });
    expect(report.media.copied).toBe(1);
    expect(tableRows()).toEqual(before);
    expect(readdirSync(mediaRoot)).toEqual([]);
    expect(formatReport(report)).toMatch(/^DRY RUN/);
    // …and the real run after it works.
    await run();
    expect(tableRows().users).toBe(5);
  });

  it("refuses a database that has accounts, unless forced", async () => {
    makeUser(db, { email: "anna@example.com", password: "kept" });
    await expect(run()).rejects.toBeInstanceOf(ImportRefused);
    expect(tableRows().families).toBe(0);

    const report = await run({ force: true });
    const anna = user("anna@example.com")!;
    expect(anna.password).toBe("kept"); // the existing account is kept as it was
    expect(role(FP.krug, "anna@example.com")).toBe("editor");
    expect(report.users.find((u) => u.email === "anna@example.com")).toMatchObject({ existing: true });
    expect(findToken(db, FP.apiToken, "api", NOW)?.user.id).toBe(anna.id);
  });

  it("a second run fails cleanly, even forced", async () => {
    await run();
    const after = tableRows();
    await expect(run()).rejects.toThrow(/isn't empty/);
    await expect(run({ force: true }, allSources())).rejects.toThrow(/imported before/);
    expect(tableRows()).toEqual(after);
  });

  it("is all or nothing: a failure rolls back the rows and the copied photos", async () => {
    // A different file where the salad photo would go makes the cookless area fail…
    const s = allSources();
    const otherMedia = mkdtempSync(join(dir, "media-src-"));
    mkdirSync(join(otherMedia, "recipes"), { recursive: true });
    writeFileSync(join(otherMedia, CK.pastaImage), "pasta");
    writeFileSync(join(otherMedia, "recipes/missing.webp"), "salad");
    mkdirSync(join(mediaRoot, "recipes"), { recursive: true });
    writeFileSync(join(mediaRoot, "recipes/missing.webp"), "something else");
    s.cookless!.mediaDir = otherMedia;

    await expect(run({}, s)).rejects.toThrow(/cookless: meals: .*exists already/);
    expect(tableRows()).toMatchObject({ users: 0, families: 0, recipes: 0, ingredients: 2 });
    expect(existsSync(join(mediaRoot, CK.pastaImage))).toBe(false); // copied, then removed again
    expect(readFileSync(join(mediaRoot, "recipes/missing.webp"), "utf8")).toBe("something else");
  });
});
