import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { and, eq } from "drizzle-orm";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import {
  apptIgnored,
  apptRuns,
  apptSearchChannels,
  apptSearches,
  authTokens,
  calEntries,
  calEntryTypes,
  calNotes,
  cookingSteps,
  families,
  familyMembers,
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
import { DEFAULT_TAGS } from "@/lib/meals/recipes/tag-defaults";
import { SecretBox, devSecret } from "@/lib/secrets";
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

const run = (opts: { dryRun?: boolean; force?: boolean } = {}, s: ImportSources = sources) =>
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
    expect(db.select().from(users).all()).toHaveLength(0);
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

    expect(report.notes.some((n) => n.includes("Gemini API key") && n.includes(FP.krug))).toBe(true);
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

  it("reports the counts and what family-planner has that isn't imported yet", async () => {
    const report = await run();
    expect(report.counts).toMatchObject({ users: 5, families: 4, family_members: 6, recipes: 3, appt_searches: 2, cal_notes: 2 });
    expect(report.notes.some((n) => n.includes("finance_categories (1)"))).toBe(true);
    expect(report.notes.join("\n")).not.toContain("rate_limits");
  });

  it("works with one source alone", async () => {
    const report = await run({}, { fma: openFma(fmaPath) });
    expect(report.counts.families).toBe(2);
    expect(db.select().from(families).all().map((f) => f.id).sort()).toEqual([FMA.erik, FMA.krug].sort());
    expect(report.notes.some((n) => n.includes("no family-planner source was given"))).toBe(true);
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
