// Bank sync of finance accounts (lib/finance/bank/): linking an account to comdirect, the sync
// the worker's BankSyncRunner runs (login, TAN by push or typed, accounts, transactions,
// import), the lockout guards and the mapping of comdirect's rows. comdirect is the fake of
// lib/test/comdirect.ts; nothing touches the network.

import Database from "better-sqlite3";
import { and, eq } from "drizzle-orm";
import { drizzle } from "drizzle-orm/better-sqlite3";
import { migrate } from "drizzle-orm/better-sqlite3/migrator";
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { createFamilyApi } from "@/lib/api/family-api";
import { createToken } from "@/lib/auth/tokens";
import { handleFamily } from "@/lib/calendar/family-routes";
import { handleCalendar } from "@/lib/calendar/vacation";
import { addDays } from "@/lib/calendar/dates";
import * as schema from "@/lib/db/schema";
import { finBankLinks, finBankSyncs, finTransactions } from "@/lib/db/schema";
import { centsOf, mapCardTransaction, mapTransaction, remittanceLines } from "@/lib/finance/bank/comdirect";
import { BankSyncRunner, FULL_SYNC_DAYS } from "@/lib/finance/bank/runner";
import { pruneSyncs } from "@/lib/finance/bank/queue";
import { handleFinance } from "@/lib/finance/finance";
import {
  FAKE_PHOTO_TAN,
  type FakeComdirect,
  GIRO,
  SAVINGS,
  VISA,
  VISA_2,
  fakeComdirect,
  remittance,
} from "@/lib/test/comdirect";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const BASE = "http://ohana.test/api/v1";

/** The server's local day of NOW, and the first day a full sync asks for. */
const pad = (n: number) => String(n).padStart(2, "0");
const TODAY = `${NOW.getFullYear()}-${pad(NOW.getMonth() + 1)}-${pad(NOW.getDate())}`;
const FULL_FROM = addDays(TODAY, -FULL_SYNC_DAYS);

type Res = { status: number; data: any }; // eslint-disable-line @typescript-eslint/no-explicit-any

const CREDENTIALS = { clientId: "client-id", clientSecret: "client-secret", username: "12345678", pin: "4711" };

/** A card payment whose merchant fills the first line and wraps onto the second. */
const CARD_FIRST = "AMZN Mktp DE*NI22A6FP4, AMZN.COM BI";

function giroTransactions(): unknown[] {
  return [
    {
      reference: "5012345678901234/1",
      bookingStatus: "BOOKED",
      bookingDate: "2026-10-20",
      valutaDate: "2026-10-32",
      amount: { value: "-23.45", unit: "EUR" },
      remitter: null,
      deptor: null,
      creditor: null,
      remittanceInfo: remittance(CARD_FIRST, "LL  LU", "Karte Nr. 4871 78XX XXXX 3636", "Kartenzahlung"),
      transactionType: { key: "CARD_TRANSACTION", text: "Card transaction" },
      newTransaction: false,
    },
    {
      reference: "5012345678901234/2",
      bookingStatus: "BOOKED",
      bookingDate: "2026-10-15",
      amount: { value: "-49.99", unit: "EUR" },
      remitter: { holderName: "Stadtwerke Musterstadt GmbH", iban: "DE11", bic: "X" },
      deptor: { holderName: "Max Mustermann" },
      creditor: null,
      remittanceInfo: remittance(
        "Abschlag Strom Oktober",
        "End-to-End-Ref.:",
        "E2E-123",
        "CORE / Mandatsref.:",
        "M-42",
        "Gläubiger-ID:",
        "DE98ZZZ09999999999",
      ),
      transactionType: { key: "DIRECT_DEBIT", text: "Direct Debit" },
    },
    {
      // No reference: counted by its content.
      bookingStatus: "BOOKED",
      bookingDate: "2026-10-10",
      amount: { value: "-5.00", unit: "EUR" },
      remittanceInfo: remittance("Entgelt", "Kontoführung"),
      transactionType: { key: "BANK_FEES", text: "Bank fees" },
    },
    {
      reference: "5012345678901234/3",
      bookingStatus: "BOOKED",
      bookingDate: "2026-10-05",
      amount: { value: "-100.10", unit: "EUR" },
      remitter: null,
      deptor: { holderName: "Max Mustermann" },
      creditor: { holderName: "Erika  Mustermann", iban: "DE22" },
      remittanceInfo: remittance("Miete Oktober", "End-to-End-Ref.:", "nicht angegeben"),
      transactionType: { key: "TRANSFER", text: "Transfer" },
    },
    {
      reference: "5012345678901234/4",
      bookingStatus: "BOOKED",
      bookingDate: "2026-10-01",
      amount: { value: "2500.00", unit: "EUR" },
      remitter: { holderName: "ACME GmbH" },
      creditor: { holderName: "Max Mustermann" },
      remittanceInfo: remittance("Gehalt Oktober"),
      transactionType: { key: "TRANSFER", text: "Transfer" },
    },
    // Skipped: no booking day, no amount.
    { reference: "x1", bookingStatus: "BOOKED", bookingDate: null, amount: { value: "-1.00", unit: "EUR" } },
    { reference: "x2", bookingStatus: "BOOKED", bookingDate: "2026-10-02", amount: null },
  ];
}

const savingsTransactions = () => [
  {
    reference: "TG/1",
    bookingStatus: "BOOKED",
    bookingDate: "2026-10-03",
    amount: { value: "1.23", unit: "EUR" },
    remitter: { holderName: "comdirect bank AG" },
    remittanceInfo: remittance("Zinsen"),
    transactionType: { key: "MISCELLANEOUS", text: "Miscellaneous" },
  },
];

/** A credit card's rows as comdirect's card endpoint lists them, newest first. */
const cardTransactions = () => [
  {
    // The monthly bill, paid from the Girokonto.
    reference: "188000000004",
    bookingStatus: "BOOKED",
    bookingDate: "2026-11-01",
    transactionValueInEUR: { value: "61.98", unit: "EUR" },
    transactionValue: { value: "61.98", unit: "EUR" },
    transaktionDate: "2026-10-31",
    newTransaction: true,
    remittanceInfo: ["Visa-Kartenabrechnung"],
    categoryDisplayName: "Visa-Kartenabrechnung",
    transactionDirection: "IN",
    exchangeRate: 1,
  },
  {
    reference: "188000000003",
    bookingStatus: "BOOKED",
    bookingDate: "2026-10-28",
    transactionValueInEUR: { value: "-11.52", unit: "EUR" },
    transactionValue: { value: "-12.34", unit: "USD" },
    transaktionDate: "2026-10-27",
    remittanceInfo: ["UBER   *TRIP HELP.UBER.COM"],
    categoryDisplayName: "Kartenumsatz",
    transactionDirection: "OUT",
    exchangeRate: 1.0712,
  },
  {
    reference: "188000000002",
    bookingStatus: "BOOKED",
    bookingDate: "2026-10-20",
    transactionValueInEUR: { value: "-4.99", unit: "EUR" },
    transactionValue: { value: "-4.99", unit: "EUR" },
    transaktionDate: "2026-10-19",
    remittanceInfo: ["PAYPAL LEBARA LEBARA GER"],
    categoryDisplayName: "Kartenumsatz",
    transactionDirection: "OUT",
    exchangeRate: 1,
  },
  {
    reference: "188000000001",
    bookingStatus: "BOOKED",
    bookingDate: "2026-10-12",
    transactionValueInEUR: { value: "15.00", unit: "EUR" },
    transactionValue: { value: "15.00", unit: "EUR" },
    transaktionDate: "2026-10-11",
    remittanceInfo: ["AMAZON EU S.A R.L."],
    categoryDisplayName: "Gutschrift",
    transactionDirection: "IN",
    exchangeRate: 1,
  },
  // Not booked yet: skipped.
  {
    reference: "188000000005",
    bookingStatus: "NOTBOOKED",
    bookingDate: "2026-11-01",
    transactionValueInEUR: { value: "-9.99", unit: "EUR" },
    transaktionDate: "2026-11-01",
    remittanceInfo: ["NETFLIX.COM"],
    transactionDirection: "OUT",
  },
];

let runners: BankSyncRunner[] = [];
afterEach(async () => {
  await Promise.all(runners.map((r) => r.stop(2000)));
  runners = [];
});

function setup(options: Parameters<typeof fakeComdirect>[0] = {}) {
  const db = createTestDb();
  const bank: FakeComdirect = fakeComdirect({
    transactions: { [GIRO.accountId]: giroTransactions(), [SAVINGS.accountId]: savingsTransactions() },
    cards: [VISA_2, VISA],
    cardTransactions: { [VISA.cardId]: cardTransactions() },
    ...options,
  });
  const runner = new BankSyncRunner(db, {
    fetch: bank.fetch,
    now: () => NOW,
    timing: { requestTimeoutMs: 2000, tanTimeoutMs: 2000, pushPollMs: 5 },
    tanPollMs: 5,
    log: () => {},
  });
  runners.push(runner);
  const handler = createFamilyApi([handleFamily, handleCalendar, handleFinance], {
    db,
    appUrl: "http://ohana.test",
    now: () => NOW,
  });
  const owner = makeUser(db, { email: "owner@test" });
  const viewer = makeUser(db, { email: "viewer@test" });
  const family = makeFamily(db, owner.id, [{ userId: viewer.id, role: "viewer" }]);
  const f = `/families/${family.id}/finance`;
  const as = (userId: string) => {
    const token = createToken(db, { userId, kind: "api" }, NOW).token;
    return async (method: string, path: string, body?: unknown): Promise<Res> => {
      const res = await handler(
        new Request(BASE + path, {
          method,
          headers: { authorization: `Bearer ${token}`, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
          body: body !== undefined ? JSON.stringify(body) : undefined,
        }),
      );
      return { status: res.status, data: await res.json() };
    };
  };
  const call = as(owner.id);
  const view = as(viewer.id);
  const link = () => db.select().from(finBankLinks).get();
  const transactions = () =>
    db.select().from(finTransactions).where(eq(finTransactions.familyId, family.id)).all()
      .sort((a, b) => b.day.localeCompare(a.day));
  /** Ticks until the sync of `account` is in `status` (or fails the test). */
  const until = async (status: string, account = "giro") => {
    for (let i = 0; i < 400; i++) {
      runner.tick();
      const res = await call("GET", `${f}/accounts/${account}/bank/sync`);
      if (res.data.status === status) return res.data;
      await new Promise((r) => setTimeout(r, 5));
    }
    throw new Error(`the sync didn't get to ${status}: ${JSON.stringify((await call("GET", `${f}/accounts/${account}/bank/sync`)).data)}`);
  };
  /** Starts a sync and runs it to the end. */
  const sync = async (account = "giro", body: Record<string, unknown> = {}) => {
    const started = await call("POST", `${f}/accounts/${account}/bank/sync`, body);
    expect(started.status, JSON.stringify(started.data)).toBe(202);
    runner.tick();
    await runner.idle(5000);
    return (await call("GET", `${f}/accounts/${account}/bank/sync`)).data;
  };
  return { db, bank, runner, call, view, f, family, owner, link, transactions, until, sync };
}

/** With an account "Giro" linked to comdirect. */
async function linked(options: Parameters<typeof fakeComdirect>[0] = {}, iban: string | null = null) {
  const t = setup(options);
  expect((await t.call("POST", `${t.f}/accounts`, { name: "Giro", color: "#3b82f6" })).status).toBe(201);
  const res = await t.call("PUT", `${t.f}/accounts/giro/bank`, { provider: "comdirect", ...CREDENTIALS, iban });
  expect(res.status, JSON.stringify(res.data)).toBe(200);
  return t;
}

describe("linking an account to its bank", () => {
  it("links, edits and unlinks, without ever showing the secrets", async () => {
    const { call, view, f, link, db } = setup();
    await call("POST", `${f}/accounts`, { name: "Giro", color: "#3b82f6" });
    // A new link needs every secret.
    const partial = await call("PUT", `${f}/accounts/giro/bank`, { provider: "comdirect", clientId: "a", username: "b", pin: "c" });
    expect(partial.status).toBe(400);
    expect(partial.data.error).toContain("clientSecret");
    expect((await call("PUT", `${f}/accounts/giro/bank`, { provider: "sparkasse", ...CREDENTIALS })).status).toBe(400);
    expect((await call("PUT", `${f}/accounts/giro/bank`, { provider: "comdirect", ...CREDENTIALS, iban: "nope" })).status).toBe(400);
    expect((await call("PUT", `${f}/accounts/nope/bank`, { provider: "comdirect", ...CREDENTIALS })).status).toBe(404);

    const res = await call("PUT", `${f}/accounts/giro/bank`, { provider: "comdirect", ...CREDENTIALS, iban: "de89 3704 0044 0532 0130 00" });
    expect(res.status).toBe(200);
    expect(res.data).toEqual({
      id: "giro",
      name: "Giro",
      color: "#3b82f6",
      icon: "",
      openingCents: 0,
      position: 0,
      balanceCents: 0,
      bank: { provider: "comdirect", iban: "DE89370400440532013000", card: null, lastSyncAt: null },
    });
    // Sealed in the database, never in an answer.
    const stored = link()!;
    expect(stored.credentials.startsWith("v1:")).toBe(true);
    for (const secret of Object.values(CREDENTIALS)) {
      expect(stored.credentials).not.toContain(secret);
    }
    const overview = await view("GET", f);
    expect(overview.data.accounts[0].bank).toEqual({ provider: "comdirect", iban: "DE89370400440532013000", card: null, lastSyncAt: null });
    expect((await call("GET", `${f}/accounts`)).data.accounts[0].bank.provider).toBe("comdirect");
    const everything = JSON.stringify([overview.data, (await call("GET", `/families/${link()!.familyId}/export`)).data]);
    for (const secret of Object.values(CREDENTIALS)) expect(everything).not.toContain(secret);
    // Not in the family's export file at all.
    expect(JSON.stringify((await call("GET", `/families/${link()!.familyId}/export`)).data)).not.toContain("comdirect");

    // Editing: blank secrets keep the stored ones; the IBAN can be cleared.
    db.update(finBankLinks).set({ unconfirmedTans: 2, session: "v1:x" }).run();
    const edited = await call("PUT", `${f}/accounts/giro/bank`, { provider: "comdirect", clientId: "", pin: "", iban: null });
    expect(edited.status).toBe(200);
    expect(edited.data.bank.iban).toBeNull();
    expect(link()!.unconfirmedTans).toBe(0);
    expect(link()!.session).toBe("v1:x"); // the same login keeps its session
    const repinned = await call("PUT", `${f}/accounts/giro/bank`, { provider: "comdirect", pin: "9999" });
    expect(repinned.data.bank.iban).toBeNull();
    expect(link()!.session).toBeNull();

    // Viewers read, but don't change.
    expect((await view("PUT", `${f}/accounts/giro/bank`, { provider: "comdirect", ...CREDENTIALS })).status).toBe(403);
    expect((await view("DELETE", `${f}/accounts/giro/bank`)).status).toBe(403);
    expect((await view("POST", `${f}/accounts/giro/bank/sync`, {})).status).toBe(403);
    expect((await view("GET", `${f}/accounts/giro/bank/sync`)).status).toBe(404);

    const unlinked = await call("DELETE", `${f}/accounts/giro/bank`);
    expect(unlinked.status).toBe(200);
    expect(unlinked.data.bank).toBeNull();
    expect(link()).toBeUndefined();
    expect((await call("POST", `${f}/accounts/giro/bank/sync`, {})).status).toBe(409);
  });

  it("refuses the CSV import of a linked account, and goes with its account", async () => {
    const { call, f, link, transactions, sync } = await linked();
    const rows = [{ date: "2026-10-01", amountCents: -100, payee: "Bakery" }];
    const refused = await call("POST", `${f}/import`, { rows, accountId: "giro" });
    expect(refused.status).toBe(409);
    expect(refused.data).toEqual({ error: "This account syncs with its bank" });
    await call("POST", `${f}/accounts`, { name: "Cash", color: "#22c55e" });
    expect((await call("POST", `${f}/import`, { rows, accountId: "cash" })).data.ids).toHaveLength(1);

    expect((await sync()).status).toBe("done");
    // Unlinking keeps the transactions.
    await call("DELETE", `${f}/accounts/giro/bank`);
    expect(transactions().filter((t) => t.accountId === "giro").length).toBe(5);
    await call("PUT", `${f}/accounts/giro/bank`, { provider: "comdirect", ...CREDENTIALS });
    expect(link()).toBeDefined();
    // Deleting the account deletes its link and syncs.
    expect((await call("DELETE", `${f}/accounts/giro`)).status).toBe(200);
    expect(link()).toBeUndefined();
  });
});

describe("syncing with comdirect", () => {
  it("logs in with a push TAN, imports the booked transactions and dedupes the next sync", async () => {
    const { call, f, bank, runner, link, transactions, until } = await linked({ approveAfter: null });
    const started = await call("POST", `${f}/accounts/giro/bank/sync`, {});
    expect(started.status).toBe(202);
    expect(started.data).toMatchObject({ accountId: "giro", status: "waiting", step: null, tan: null, result: null, error: null });
    // Starting again gives the same one.
    const again = await call("POST", `${f}/accounts/giro/bank/sync`, {});
    expect([again.status, again.data.id]).toEqual([200, started.data.id]);

    expect(runner.tick()).toBe(1);
    expect((await call("GET", `${f}/accounts/giro/bank/sync`)).data).toMatchObject({ status: "running", step: "login" });
    const tan = await until("tan");
    expect(tan.tan).toEqual({ type: "push", image: null, hint: null });
    expect(tan.step).toBe("tan");
    // Nothing to type for a push.
    expect((await call("POST", `${f}/accounts/giro/bank/sync/tan`, { tan: "123456" })).status).toBe(409);
    expect(link()!.unconfirmedTans).toBe(1);
    bank.approve();
    await runner.idle(5000);

    const done = (await call("GET", `${f}/accounts/giro/bank/sync`)).data;
    expect(done.status).toBe("done");
    expect(done.step).toBeNull();
    expect(done.result).toMatchObject({ added: 5, duplicates: 0, transfers: 0, splits: 0 });
    expect(done.result.ids).toHaveLength(5);
    expect(bank.state.problems).toEqual([]);
    expect(bank.state.validates).toBe(1);
    expect(bank.state.patches).toBe(1);
    expect(bank.state.tans).toEqual([null]);
    expect(link()!.unconfirmedTans).toBe(0);
    expect(link()!.syncedThrough).toBe("2026-10-20");
    expect(link()!.session).toMatch(/^v1:/);
    // An empty account: two years back.
    const today = new Date(NOW.getFullYear(), NOW.getMonth(), NOW.getDate());
    const day = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, "0")}-${String(today.getDate()).padStart(2, "0")}`;
    expect(bank.state.minBookingDates).toEqual([addDays(day, -730)]);

    expect(transactions().map((t) => [t.day, t.amountCents, t.payee, t.description, t.accountId])).toEqual([
      ["2026-10-20", -2345, "AMZN Mktp DE*NI22A6FP4, AMZN.COM BILL LU", "Karte Nr. 4871 78XX XXXX 3636 Kartenzahlung", "giro"],
      ["2026-10-15", -4999, "Stadtwerke Musterstadt GmbH", "Abschlag Strom Oktober", "giro"],
      ["2026-10-10", -500, "Entgelt", "Kontoführung", "giro"],
      ["2026-10-05", -10010, "Erika Mustermann", "Miete Oktober", "giro"],
      ["2026-10-01", 250000, "ACME GmbH", "Gehalt Oktober", "giro"],
    ]);
    const account = (await call("GET", f)).data.accounts[0];
    expect(account.balanceCents).toBe(250000 - 2345 - 4999 - 500 - 10010);
    expect(account.bank.lastSyncAt).toBe(NOW.toISOString());

    // Again soon after: the stored session is refreshed, no TAN, nothing twice.
    const second = await call("POST", `${f}/accounts/giro/bank/sync`, {});
    expect(second.status).toBe(202);
    expect(second.data.id).not.toBe(started.data.id);
    runner.tick();
    await runner.idle(5000);
    const resynced = (await call("GET", `${f}/accounts/giro/bank/sync`)).data;
    expect(resynced.status).toBe("done");
    expect(resynced.result).toEqual({ added: 0, duplicates: 3, transfers: 0, splits: 0, ids: [] });
    expect(bank.state.validates).toBe(1);
    expect(bank.state.refreshes).toBe(1);
    expect(bank.state.minBookingDates[1]).toBe("2026-10-06"); // 14 days before the last booking
    expect(transactions()).toHaveLength(5);

    // The session ran out: a full login with a TAN again, a new booking comes in.
    bank.expireSessions();
    bank.opts.approveAfter = 1;
    bank.opts.transactions[GIRO.accountId].unshift({
      reference: "5012345678901234/5",
      bookingStatus: "BOOKED",
      bookingDate: "2026-10-30",
      amount: { value: "-7.5", unit: "EUR" },
      creditor: { holderName: "Bäckerei" },
      transactionType: { key: "TRANSFER", text: "Transfer" },
    });
    await call("POST", `${f}/accounts/giro/bank/sync`, {});
    runner.tick();
    await runner.idle(5000);
    const third = (await call("GET", `${f}/accounts/giro/bank/sync`)).data;
    expect(third.status).toBe("done");
    expect(third.result).toMatchObject({ added: 1, duplicates: 3 });
    expect(bank.state.validates).toBe(2);
    expect(transactions()[0]).toMatchObject({ day: "2026-10-30", amountCents: -750, payee: "Bäckerei", description: "Transfer" });
    expect(bank.state.problems).toEqual([]);
  });

  it("takes a typed photoTAN through the route", async () => {
    const { call, f, bank, runner, until, view } = await linked({ tanType: "P_TAN" });
    await call("POST", `${f}/accounts/giro/bank/sync`, {});
    const tan = await until("tan");
    expect(tan.tan).toEqual({ type: "photo", image: FAKE_PHOTO_TAN, hint: null });
    expect((await call("POST", `${f}/accounts/giro/bank/sync/tan`, { tan: "" })).status).toBe(400);
    expect((await view("POST", `${f}/accounts/giro/bank/sync/tan`, { tan: "123456" })).status).toBe(403);
    const sent = await call("POST", `${f}/accounts/giro/bank/sync/tan`, { tan: "123 456" });
    expect(sent.status).toBe(200);
    expect(sent.data.id).toBe(tan.id);
    await runner.idle(5000);
    const done = (await call("GET", `${f}/accounts/giro/bank/sync`)).data;
    expect(done.status).toBe("done");
    expect(done.result.added).toBe(5);
    expect(bank.state.tans).toEqual(["123456"]);
    // No TAN asked for any more.
    expect((await call("POST", `${f}/accounts/giro/bank/sync/tan`, { tan: "123456" })).status).toBe(409);
  });

  it("shows an SMS TAN's hint", async () => {
    const { call, f, runner, until } = await linked({ tanType: "M_TAN" });
    await call("POST", `${f}/accounts/giro/bank/sync`, {});
    expect((await until("tan")).tan).toEqual({ type: "sms", image: null, hint: "+49******123" });
    await call("POST", `${f}/accounts/giro/bank/sync/tan`, { tan: "123456" });
    await runner.idle(5000);
    expect((await call("GET", `${f}/accounts/giro/bank/sync`)).data.status).toBe("done");
  });

  it("fails on a wrong TAN without trying it again", async () => {
    const { call, f, bank, runner, until, link, transactions } = await linked({ tanType: "P_TAN" });
    await call("POST", `${f}/accounts/giro/bank/sync`, {});
    await until("tan");
    await call("POST", `${f}/accounts/giro/bank/sync/tan`, { tan: "000000" });
    await runner.idle(5000);
    for (let i = 0; i < 3; i++) runner.tick();
    await runner.idle(5000);
    const failed = (await call("GET", `${f}/accounts/giro/bank/sync`)).data;
    expect(failed.status).toBe("failed");
    expect(failed.error).toMatch(/didn't accept the TAN/);
    expect(bank.state.patches).toBe(1);
    expect(bank.state.validates).toBe(1);
    expect(link()!.unconfirmedTans).toBe(1);
    expect(transactions()).toHaveLength(0);
  });

  it("fails when the push isn't approved, and on a wrong PIN", async () => {
    const declined = await linked({ declinePush: true });
    const res = await declined.sync();
    expect(res).toMatchObject({ status: "failed", error: "The login wasn't approved in the comdirect app" });
    expect(declined.bank.state.patches).toBe(0);

    const wrong = await linked({ pin: "0000" });
    const bad = await wrong.sync();
    expect(bad.status).toBe("failed");
    expect(bad.error).toMatch(/Zugangsnummer/);
    expect(wrong.bank.state.validates).toBe(0);
    expect(wrong.link()!.unconfirmedTans).toBe(0);
    // Not tried again until the connection is saved again.
    expect(wrong.link()!.loginRefused).toBe(true);
    const refused = await wrong.call("POST", `${wrong.f}/accounts/giro/bank/sync`, {});
    expect(refused.status).toBe(409);
    expect(refused.data.error).toMatch(/refused the login last time/);
    wrong.bank.opts.pin = "4711";
    expect((await wrong.call("PUT", `${wrong.f}/accounts/giro/bank`, { provider: "comdirect" })).status).toBe(200);
    expect(wrong.link()!.loginRefused).toBe(false);
    expect((await wrong.sync()).status).toBe("done");
  });

  it("cancels a sync that waits for the TAN", async () => {
    const { call, view, f, bank, runner, until, link, transactions } = await linked({ approveAfter: null });
    await call("POST", `${f}/accounts/giro/bank/sync`, {});
    await until("tan");
    expect((await view("DELETE", `${f}/accounts/giro/bank/sync`)).status).toBe(403);
    const cancelled = await call("DELETE", `${f}/accounts/giro/bank/sync`);
    expect(cancelled.status).toBe(200);
    expect(cancelled.data).toMatchObject({ status: "failed", error: "Cancelled", tan: null, step: null });
    bank.approve();
    runner.tick(); // notices it
    await runner.idle(5000);
    expect((await call("GET", `${f}/accounts/giro/bank/sync`)).data).toMatchObject({ status: "failed", error: "Cancelled" });
    expect(bank.state.patches).toBe(0);
    expect(transactions()).toHaveLength(0);
    // The challenge nobody confirmed still counts.
    expect(link()!.unconfirmedTans).toBe(1);
    // Cancelling an ended one only answers it.
    expect((await call("DELETE", `${f}/accounts/giro/bank/sync`)).data.error).toBe("Cancelled");
  });

  it("never runs a lost sync again: it fails as interrupted", async () => {
    const { db, call, f, family, bank, runner } = await linked();
    const id = "11111111-1111-4111-8111-111111111111";
    db.insert(finBankSyncs).values({
      id,
      familyId: family.id,
      accountId: "giro",
      status: "tan",
      step: "tan",
      tan: JSON.stringify({ type: "push", image: null, hint: null }),
      runToken: "another-worker",
      lockedUntil: new Date(NOW.getTime() - 1000),
      createdAt: NOW,
      updatedAt: NOW,
    }).run();
    expect(runner.tick()).toBe(0);
    await runner.idle(5000);
    expect((await call("GET", `${f}/accounts/giro/bank/sync`)).data).toMatchObject({ id, status: "failed", error: "Interrupted" });
    expect(bank.state.calls).toEqual([]);

    // A worker that stops leaves its sync interrupted too.
    bank.opts.approveAfter = null;
    await call("POST", `${f}/accounts/giro/bank/sync`, {});
    runner.tick();
    for (let i = 0; i < 200 && (await call("GET", `${f}/accounts/giro/bank/sync`)).data.status !== "tan"; i++) {
      await new Promise((r) => setTimeout(r, 5));
    }
    await runner.stop(2000);
    expect((await call("GET", `${f}/accounts/giro/bank/sync`)).data).toMatchObject({ status: "failed", error: "Interrupted" });
    expect(bank.state.patches).toBe(0);
  });

  it("refuses to start after three unconfirmed TANs until the link is saved again", async () => {
    const { call, f, db, bank, link, sync } = await linked();
    db.update(finBankLinks).set({ unconfirmedTans: 3 }).run();
    const refused = await call("POST", `${f}/accounts/giro/bank/sync`, {});
    expect(refused.status).toBe(409);
    expect(refused.data.error).toMatch(/log in once on the bank's website/);
    expect(bank.state.calls).toEqual([]);
    // Saving the connection again (blank secrets keep them) resets the guard.
    expect((await call("PUT", `${f}/accounts/giro/bank`, { provider: "comdirect" })).status).toBe(200);
    expect(link()!.unconfirmedTans).toBe(0);
    expect((await sync()).status).toBe("done");
  });

  it("picks the account by IBAN, else the only Girokonto, and says which ones there are otherwise", async () => {
    // Only one Girokonto (and a Tagesgeld): that one.
    const one = await linked({ accounts: [SAVINGS, GIRO] });
    expect((await one.sync()).result.added).toBe(5);

    // By IBAN.
    const byIban = await linked({ accounts: [GIRO, SAVINGS] }, SAVINGS.iban);
    const done = await byIban.sync();
    expect(done.result.added).toBe(1);
    expect(byIban.transactions()[0]).toMatchObject({ payee: "comdirect bank AG", amountCents: 123, description: "Zinsen" });

    // An IBAN comdirect doesn't have.
    const missing = await linked({ accounts: [GIRO] }, "DE44500105175407324931");
    const failed = await missing.sync();
    expect(failed.status).toBe("failed");
    expect(failed.error).toContain("DE44500105175407324931");
    expect(failed.error).toContain(GIRO.iban);

    // Two Girokonten and no IBAN: the user has to say which.
    const other = { ...GIRO, accountId: "ACC-GIRO-2", iban: "DE75512108001245126199" };
    const ambiguous = await linked({ accounts: [GIRO, other, SAVINGS] });
    const which = await ambiguous.sync();
    expect(which.status).toBe("failed");
    expect(which.error).toContain(`${GIRO.iban} (Girokonto)`);
    expect(which.error).toContain(`${other.iban} (Girokonto)`);
    expect(which.error).toContain(`${SAVINGS.iban} (Tagesgeld PLUS)`);
    expect(ambiguous.transactions()).toHaveLength(0);
  });

  it("first syncs an account with transactions from its latest day on", async () => {
    const { call, f, bank, sync, transactions, link } = await linked();
    await call("POST", `${f}/transactions`, {
      ops: [{ date: "2026-10-12", amountCents: -999, payee: "From a CSV file", accountId: "giro" }],
    });
    const done = await sync();
    expect(done.result.added).toBe(2);
    expect(bank.state.minBookingDates).toEqual(["2026-10-12"]);
    expect(link()!.syncedFrom).toBe("2026-10-12");
    expect(transactions().map((t) => t.day)).toEqual(["2026-10-20", "2026-10-15", "2026-10-12"]);
  });

  it("never adds a CSV file's bookings again, also not on its last day or in a later sync", async () => {
    const { call, f, bank, sync, transactions, link } = await linked();
    // The account's history from a CSV file (other texts than the bank's), up to 15 October.
    const csv = [
      { date: "2026-10-01", amountCents: 250000, payee: "ACME GMBH", description: "GEHALT" },
      { date: "2026-10-05", amountCents: -10010, payee: "ERIKA MUSTERMANN", description: "MIETE" },
      { date: "2026-10-10", amountCents: -500, payee: "COMDIRECT", description: "ENTGELT" },
      { date: "2026-10-15", amountCents: -4999, payee: "STADTWERKE", description: "ABSCHLAG" },
    ];
    expect((await call("POST", `${f}/transactions`, { ops: csv.map((t) => ({ ...t, accountId: "giro" })) })).status).toBe(200);
    // Later on the CSV's last day: a booking the file didn't have yet.
    const giro = bank.opts.transactions[GIRO.accountId];
    giro.unshift({
      reference: "5012345678901234/6",
      bookingStatus: "BOOKED",
      bookingDate: "2026-10-15",
      amount: { value: "-3.20", unit: "EUR" },
      creditor: { holderName: "Kiosk" },
      transactionType: { key: "CARD_TRANSACTION", text: "Card transaction" },
    });

    const first = await sync();
    expect(first.status).toBe("done");
    expect(bank.state.minBookingDates).toEqual(["2026-10-15"]);
    // The Stadtwerke's is the CSV's; the kiosk's and the card payment of the 20th are new.
    expect(first.result).toMatchObject({ added: 2, duplicates: 1 });
    expect(link()!.syncedFrom).toBe("2026-10-15");

    // A few days later: 14 days before the 20th would reach the CSV's 10th; it starts at the 15th.
    // One more booking of the 15th with the CSV's amount is a booking of its own.
    giro.unshift({
      reference: "5012345678901234/7",
      bookingStatus: "BOOKED",
      bookingDate: "2026-10-15",
      amount: { value: "-49.99", unit: "EUR" },
      creditor: { holderName: "Stadtwerke Musterstadt GmbH" },
      transactionType: { key: "DIRECT_DEBIT", text: "Direct Debit" },
    });
    const second = await sync();
    expect(second.status).toBe("done");
    expect(bank.state.minBookingDates[1]).toBe("2026-10-15");
    expect(second.result).toMatchObject({ added: 1, duplicates: 3 });
    const third = await sync();
    expect(third.result).toMatchObject({ added: 0, duplicates: 4 });

    expect(transactions().map((t) => [t.day, t.amountCents]).sort()).toEqual([
      ["2026-10-01", 250000],
      ["2026-10-05", -10010],
      ["2026-10-10", -500],
      ["2026-10-15", -320],
      ["2026-10-15", -4999],
      ["2026-10-15", -4999],
      ["2026-10-20", -2345],
    ]);
    const account = (await call("GET", f)).data.accounts[0];
    expect(account.balanceCents).toBe(250000 - 10010 - 500 - 320 - 4999 - 4999 - 2345);
  });

  it("imports the bank's whole history on request, adopting the CSV file's transactions", async () => {
    const { db, call, view, f, bank, sync, transactions, link } = setup();
    expect((await call("POST", `${f}/accounts`, { name: "Giro", color: "#3b82f6" })).status).toBe(201);
    // The account's history from a CSV file (other texts than the bank's), and a row the bank
    // doesn't have (perhaps the file's duplicate); the bank's history starts on 1 October, so the
    // September row isn't counted. A typed one of the bank's days stays too.
    const csv = [
      { date: "2026-09-01", amountCents: -1200, payee: "OLDER THAN THE BANK", description: "" },
      { date: "2026-10-01", amountCents: 250000, payee: "ACME GMBH", description: "GEHALT" },
      { date: "2026-10-05", amountCents: -10010, payee: "ERIKA MUSTERMANN", description: "MIETE" },
      { date: "2026-10-07", amountCents: -777, payee: "NOT AT THE BANK", description: "" },
      { date: "2026-10-10", amountCents: -500, payee: "COMDIRECT", description: "ENTGELT" },
      { date: "2026-10-15", amountCents: -4999, payee: "STADTWERKE", description: "ABSCHLAG" },
    ];
    const imported = await call("POST", `${f}/import`, { accountId: "giro", rows: csv });
    expect(imported.status, JSON.stringify(imported.data)).toBe(200);
    await call("POST", `${f}/transactions`, {
      ops: [{ date: "2026-10-12", amountCents: -350, payee: "Typed", accountId: "giro" }],
    });
    const res = await call("PUT", `${f}/accounts/giro/bank`, { provider: "comdirect", ...CREDENTIALS, iban: null });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    const category = db.select().from(schema.finCategories).get()!;
    const rent = transactions().find((t) => t.amountCents === -10010)!;
    db.update(finTransactions).set({ categoryId: category.id, note: "Rent" }).where(eq(finTransactions.id, rent.id)).run();
    const csvHashes = new Map(transactions().map((t) => [t.id, t.importHash]));

    expect((await view("POST", `${f}/accounts/giro/bank/sync`, { full: true })).status).toBe(403);
    expect((await call("POST", `${f}/accounts/giro/bank/sync`, { full: "yes" })).status).toBe(400);
    const done = await sync("giro", { full: true });
    expect(done.status, JSON.stringify(done)).toBe("done");
    expect(done.full).toBe(true);
    expect(bank.state.minBookingDates).toEqual([FULL_FROM]);
    // Four of the bank's rows are the CSV's; the card payment of the 20th is new.
    expect(done.result).toMatchObject({ added: 1, duplicates: 0, adopted: 4, unmatched: 2 });
    expect(link()).toMatchObject({ syncedFrom: FULL_FROM, syncedThrough: "2026-10-20" });

    const after = transactions();
    expect(after).toHaveLength(8);
    // Adopted: the bank's hash, everything else as it was.
    const adopted = after.filter((t) => csvHashes.has(t.id) && t.importHash !== csvHashes.get(t.id));
    expect(adopted.map((t) => t.payee).sort()).toEqual(["ACME GMBH", "COMDIRECT", "ERIKA MUSTERMANN", "STADTWERKE"]);
    expect(after.find((t) => t.id === rent.id)).toMatchObject({ categoryId: category.id, note: "Rent", description: "MIETE" });
    const extra = after.find((t) => t.amountCents === -777)!;
    expect(extra.importHash).toBe(csvHashes.get(extra.id));
    // Where each came from: the adopted and new ones the bank's, the rest still the CSV file's.
    expect(after.map((t) => [t.payee, t.source]).sort()).toEqual([
      ["ACME GMBH", "bank"],
      ["AMZN Mktp DE*NI22A6FP4, AMZN.COM BILL LU", "bank"],
      ["COMDIRECT", "bank"],
      ["ERIKA MUSTERMANN", "bank"],
      ["NOT AT THE BANK", "csv"],
      ["OLDER THAN THE BANK", "csv"],
      ["STADTWERKE", "bank"],
      ["Typed", "manual"],
    ]);
    // What the bank doesn't list: the account's rows no sync brought, from its first day on.
    const left = (await call("GET", `${f}/transactions?account=giro&source=manual,csv&from=2026-10-01`)).data;
    expect(left.transactions.map((t: { payee: string; source: string }) => [t.payee, t.source])).toEqual([
      ["Typed", "manual"],
      ["NOT AT THE BANK", "csv"],
    ]);
    expect((await call("GET", `${f}/transactions?source=sync`)).status).toBe(400);

    // Later syncs know them: nothing comes twice.
    const next = await sync();
    expect(next.full).toBe(false);
    expect(next.result).toEqual({ added: 0, duplicates: 3, transfers: 0, splits: 0, ids: [] });
    const again = await sync("giro", { full: true });
    expect(again.result).toMatchObject({ added: 0, duplicates: 5, adopted: 0, unmatched: 2 });
    expect(transactions()).toHaveLength(8);
    expect(bank.state.problems).toEqual([]);
  });

  it("adopts one transaction per bank row of a day and amount, the one with its payee first", async () => {
    const { call, f, bank, sync, transactions } = await linked();
    // Two rows of the 15th with the Stadtwerke's amount: the bank has one.
    const csv = [
      { date: "2026-10-15", amountCents: -4999, payee: "Someone else", description: "" },
      { date: "2026-10-15", amountCents: -4999, payee: "stadtwerke musterstadt gmbh", description: "" },
    ];
    await call("POST", `${f}/transactions`, { ops: csv.map((t) => ({ ...t, accountId: "giro" })) });
    const hashOf = (payee: string) => transactions().find((t) => t.payee === payee)!.importHash;
    const other = hashOf("Someone else");
    const own = hashOf("stadtwerke musterstadt gmbh");
    bank.opts.transactions[GIRO.accountId] = giroTransactions().filter((t) => (t as { reference?: string }).reference === "5012345678901234/2");
    const done = await sync("giro", { full: true });
    expect(done.result).toMatchObject({ added: 0, adopted: 1, unmatched: 1 });
    expect(hashOf("Someone else")).toBe(other);
    expect(hashOf("stadtwerke musterstadt gmbh")).not.toBe(own);
    expect((await sync("giro", { full: true })).result).toMatchObject({ added: 0, duplicates: 1, adopted: 0, unmatched: 1 });
    expect(transactions()).toHaveLength(2);
  });

  it("keeps a link synced before the floor existed off the CSV's days (the migration's floor)", async () => {
    const { db, call, f, bank, sync, transactions } = await linked();
    const csv = [
      { date: "2026-10-01", amountCents: 250000, payee: "ACME GMBH", description: "GEHALT" },
      { date: "2026-10-05", amountCents: -10010, payee: "ERIKA MUSTERMANN", description: "MIETE" },
      { date: "2026-10-10", amountCents: -500, payee: "COMDIRECT", description: "ENTGELT" },
    ];
    await call("POST", `${f}/transactions`, { ops: csv.map((t) => ({ ...t, accountId: "giro" })) });
    // Synced through the 15th before: drizzle/0023 set its floor to that day.
    await call("POST", `${f}/transactions`, {
      ops: [{ date: "2026-10-15", amountCents: -4999, payee: "Stadtwerke Musterstadt GmbH", accountId: "giro" }],
    });
    db.update(finBankLinks).set({ syncedThrough: "2026-10-15", syncedFrom: "2026-10-15" }).run();
    const done = await sync();
    expect(bank.state.minBookingDates).toEqual(["2026-10-15"]);
    expect(done.result).toMatchObject({ added: 1, duplicates: 1 });
    expect(transactions().map((t) => [t.day, t.amountCents])).toEqual([
      ["2026-10-20", -2345],
      ["2026-10-15", -4999],
      ["2026-10-10", -500],
      ["2026-10-05", -10010],
      ["2026-10-01", 250000],
    ]);
  });

  it("forgets the floor with the sync history when the link gets another IBAN", async () => {
    const { call, f, sync, link } = await linked();
    await call("POST", `${f}/transactions`, {
      ops: [{ date: "2026-10-12", amountCents: -999, payee: "From a CSV file", accountId: "giro" }],
    });
    await sync();
    expect(link()).toMatchObject({ syncedFrom: "2026-10-12", syncedThrough: "2026-10-20" });
    await call("PUT", `${f}/accounts/giro/bank`, { provider: "comdirect", iban: GIRO.iban });
    expect(link()).toMatchObject({ syncedFrom: null, syncedThrough: null });
  });

  it("links transfers between the family's accounts as it imports", async () => {
    const { call, f, sync } = await linked();
    await call("POST", `${f}/accounts`, { name: "Landlord", color: "#22c55e" });
    await call("POST", `${f}/transactions`, {
      ops: [{ date: "2026-10-05", amountCents: 10010, payee: "Max Mustermann", accountId: "landlord" }],
    });
    // The rent paid from the giro account is the other leg of the landlord's.
    const done = await sync();
    expect(done.result.transfers).toBe(1);
  });

  it("prunes finished syncs after a day", async () => {
    const { db, sync } = await linked();
    await sync();
    expect(pruneSyncs(db, NOW)).toBe(0);
    expect(pruneSyncs(db, new Date(NOW.getTime() + 25 * 60 * 60_000))).toBe(1);
  });
});

describe("a credit card", () => {
  /** With an account "Visa" linked to the comdirect card ending in `card`. */
  async function cardLinked(card = "4871 78XX XXXX 0175", options: Parameters<typeof fakeComdirect>[0] = {}) {
    const t = await linked(options);
    expect((await t.call("POST", `${t.f}/accounts`, { name: "Visa", color: "#ef4444" })).status).toBe(201);
    const res = await t.call("PUT", `${t.f}/accounts/visa/bank`, { provider: "comdirect", ...CREDENTIALS, card });
    expect(res.status, JSON.stringify(res.data)).toBe(200);
    return t;
  }

  it("links by the card number's last 4 digits, instead of an IBAN", async () => {
    const { call, f, db } = setup();
    await call("POST", `${f}/accounts`, { name: "Visa", color: "#ef4444" });
    const put = (body: Record<string, unknown>) => call("PUT", `${f}/accounts/visa/bank`, { provider: "comdirect", ...body });
    const linkOf = () => db.select().from(finBankLinks).where(eq(finBankLinks.accountId, "visa")).get()!;

    const both = await put({ ...CREDENTIALS, iban: GIRO.iban, card: "0175" });
    expect(both).toEqual({ status: 400, data: { error: "Give either an IBAN or a card number" } });
    for (const card of ["12", "XXXX", "0 17 X"]) {
      const short = await put({ ...CREDENTIALS, card });
      expect(short).toEqual({ status: 400, data: { error: "card needs the card number's last 4 digits" } });
    }
    expect((await put({ ...CREDENTIALS, card: 175 })).status).toBe(400);

    const res = await put({ ...CREDENTIALS, card: "4871 78XX XXXX 0175" });
    expect(res.status).toBe(200);
    expect(res.data.bank).toEqual({ provider: "comdirect", iban: null, card: "0175", lastSyncAt: null });
    expect(linkOf().card).toBe("0175");
    expect((await call("GET", f)).data.accounts[0].bank.card).toBe("0175");

    // Saving without a card keeps it.
    db.update(finBankLinks).set({ syncedThrough: "2026-10-01" }).run();
    expect((await put({ pin: "" })).data.bank).toMatchObject({ iban: null, card: "0175" });
    expect(linkOf().syncedThrough).toBe("2026-10-01");
    // Another card starts afresh.
    expect((await put({ card: "0183" })).data.bank).toMatchObject({ iban: null, card: "0183" });
    expect(linkOf().syncedThrough).toBeNull();
    // An IBAN replaces the card, and a card the IBAN (empty ones are none).
    db.update(finBankLinks).set({ syncedThrough: "2026-10-01" }).run();
    expect((await put({ iban: GIRO.iban })).data.bank).toMatchObject({ iban: GIRO.iban, card: null });
    expect(linkOf().syncedThrough).toBeNull();
    expect((await put({ card: "0175" })).data.bank).toMatchObject({ iban: null, card: "0175" });
    expect((await put({ iban: "", card: "0183" })).data.bank).toMatchObject({ iban: null, card: "0183" });
    expect((await put({ iban: GIRO.iban, card: "" })).data.bank).toMatchObject({ iban: GIRO.iban, card: null });
    expect((await put({ iban: GIRO.iban, card: null })).data.bank).toMatchObject({ iban: GIRO.iban, card: null });
  });

  it("syncs the card's booked rows, by the day of the purchase, and nothing twice", async () => {
    const { db, bank, sync, transactions } = await cardLinked();
    const done = await sync("visa");
    expect(done.status, JSON.stringify(done)).toBe("done");
    expect(done.result).toMatchObject({ added: 4, duplicates: 0 });
    expect(bank.state.problems).toEqual([]);
    expect(bank.state.calls.filter((c) => c.includes("/cards") || c.includes("allbalances"))).toEqual([
      "GET /api/reports/participants/user/v1/allbalances",
      "GET /api/banking/v1/cards/CARD-2",
      "GET /api/banking/v1/cards/CARD-1",
      "GET /api/banking/v1/cards/CARD-1/transactions",
    ]);
    expect(bank.state.calls.some((c) => c.includes("/accounts"))).toBe(false);
    expect(transactions().map((t) => [t.day, t.amountCents, t.payee, t.description, t.accountId])).toEqual([
      ["2026-10-31", 6198, "Visa-Kartenabrechnung", "", "visa"],
      ["2026-10-27", -1152, "UBER *TRIP HELP.UBER.COM", "12.34 USD", "visa"],
      ["2026-10-19", -499, "PAYPAL LEBARA LEBARA GER", "", "visa"],
      ["2026-10-11", 1500, "AMAZON EU S.A R.L.", "Gutschrift", "visa"],
    ]);
    const visaLink = db.select().from(finBankLinks).where(eq(finBankLinks.accountId, "visa")).get()!;
    expect(visaLink.syncedThrough).toBe("2026-10-31");
    const visa = () => transactions().filter((t) => t.accountId === "visa");
    expect(visa()).toHaveLength(4);

    const again = await sync("visa");
    expect(again.result).toEqual({ added: 0, duplicates: 3, transfers: 0, splits: 0, ids: [] });
    // 14 days before the last purchase, filtered by the booking day.
    expect(bank.state.minBookingDates[1]).toBe("2026-10-17");
    expect(visa()).toHaveLength(4);
    expect(bank.state.problems).toEqual([]);
  });

  it("counts a full sync of a card complete only from the oldest day comdirect gave", async () => {
    const rows = Array.from({ length: 502 }, (_, i) => {
      const day = addDays("2026-10-31", -Math.floor(i / 2));
      return {
        reference: `R${i}`,
        bookingStatus: "BOOKED",
        bookingDate: day,
        transactionValueInEUR: { value: "-1.00", unit: "EUR" },
        transaktionDate: day,
        remittanceInfo: [`Shop ${i}`],
        transactionDirection: "OUT",
      };
    });
    const { db, sync, transactions } = await cardLinked(undefined, { cardTransactions: { [VISA.cardId]: rows } });
    const done = await sync("visa", { full: true });
    expect(done.status, JSON.stringify(done)).toBe("done");
    // The newest 500 reach back to the 250th day; that day's rows may be partial, so it's left out.
    const oldest = addDays("2026-10-31", -249);
    expect(done.result).toMatchObject({ added: 498, adopted: 0, unmatched: 0 });
    expect(transactions().every((t) => t.day > oldest)).toBe(true);
    const visaLink = db.select().from(finBankLinks).where(eq(finBankLinks.accountId, "visa")).get()!;
    expect(visaLink.syncedFrom).toBe(addDays(oldest, 1));
  });

  it("says which cards there are when none ends in the digits given", async () => {
    const { sync, transactions } = await cardLinked("1234");
    const failed = await sync("visa");
    expect(failed.status).toBe("failed");
    expect(failed.error).toBe(
      "comdirect has no card ending in 1234. Its cards: …0183 (Erika Mustermann), …0175 (Max Mustermann)",
    );
    expect(transactions()).toHaveLength(0);

    const none = await cardLinked("0175", { cards: [] });
    expect((await none.sync("visa")).error).toBe("comdirect has no card ending in 0175");
  });

  it("pairs the card's bill with the Girokonto's payment as a transfer", async () => {
    const giro = giroTransactions();
    giro.unshift({
      reference: "5012345678901234/9",
      bookingStatus: "BOOKED",
      bookingDate: "2026-11-01",
      amount: { value: "-61.98", unit: "EUR" },
      remitter: { holderName: "comdirect Visa" },
      remittanceInfo: remittance("Visa-Kartenabrechnung"),
      transactionType: { key: "DIRECT_DEBIT", text: "Direct Debit" },
    });
    const { sync, transactions } = await cardLinked("0175", { transactions: { [GIRO.accountId]: giro } });
    expect((await sync("giro")).result).toMatchObject({ added: 6, transfers: 0 });
    const done = await sync("visa");
    expect(done.result).toMatchObject({ added: 4, transfers: 1 });
    const bill = transactions().find((t) => t.accountId === "visa" && t.amountCents === 6198)!;
    const paid = transactions().find((t) => t.accountId === "giro" && t.amountCents === -6198)!;
    expect(bill.transferId).toBeTruthy();
    expect(paid.transferId).toBe(bill.transferId);
  });
});

describe("comdirect's rows", () => {
  it("reads amounts exactly", () => {
    expect(centsOf("-12.34")).toBe(-1234);
    expect(centsOf("1234567.89")).toBe(123456789);
    expect(centsOf("0.1")).toBe(10);
    expect(centsOf("7")).toBe(700);
    expect(centsOf("0.105")).toBe(11);
    expect(centsOf("-0.004")).toBe(0);
    expect(centsOf("19.99")).toBe(1999); // 19.99 * 100 is 1998.9999… as a float
    expect(centsOf("1,5")).toBeNull();
    expect(centsOf(null)).toBeNull();
  });

  it("splits the remittance lines and drops the SEPA references", () => {
    expect(remittanceLines(remittance("OBK509157898", "End-to-End-Ref.:", "td5txib5a51a530cc9408d"))).toEqual(["OBK509157898"]);
    expect(remittanceLines(remittance(CARD_FIRST, "LL  LU", "Kartenzahlung"))).toEqual([
      "AMZN Mktp DE*NI22A6FP4, AMZN.COM BILL LU",
      "Kartenzahlung",
    ]);
    expect(remittanceLines("Example payment reference\nOrder 123-4567890-1234567")).toEqual([
      "Example payment reference",
      "Order 123-4567890-1234567",
    ]);
    expect(remittanceLines(remittance("End-to-End-Ref.:", "nicht angegeben"))).toEqual([]);
    expect(remittanceLines(null)).toEqual([]);
  });

  it("maps payees by direction", () => {
    const base = { bookingStatus: "BOOKED", bookingDate: "2026-10-01", reference: "r" };
    expect(mapTransaction({ ...base, amount: { value: "-1.00" }, creditor: { holderName: "Shop" }, remitter: { holderName: "Me" } })!.payee).toBe("Shop");
    expect(mapTransaction({ ...base, amount: { value: "1.00" }, creditor: { holderName: "Me" }, remitter: { holderName: "Boss" } })!.payee).toBe("Boss");
    expect(mapTransaction({ ...base, amount: { value: "-1.00" }, debtor: { holderName: "Someone" } })!.payee).toBe("Someone");
    expect(mapTransaction({ ...base, bookingStatus: "NOTBOOKED", amount: { value: "-1.00" } })).toBeNull();
    const long = mapTransaction({ ...base, amount: { value: "-1.00" }, creditor: { holderName: "x".repeat(300) }, remittanceInfo: "y".repeat(800) })!;
    expect([long.payee.length, long.description.length]).toEqual([200, 500]);
  });
});

describe("comdirect's card rows", () => {
  const base = {
    reference: "r",
    bookingStatus: "BOOKED",
    bookingDate: "2026-11-01",
    transaktionDate: "2026-10-31",
    transactionValueInEUR: { value: "-4.99", unit: "EUR" },
    transactionValue: { value: "-4.99", unit: "EUR" },
    remittanceInfo: ["PAYPAL  LEBARA", " LEBARA GER "],
    categoryDisplayName: "Kartenumsatz",
    transactionDirection: "OUT",
  };

  it("maps a purchase", () => {
    expect(mapCardTransaction(base)).toEqual({
      day: "2026-10-31",
      amountCents: -499,
      payee: "PAYPAL LEBARA",
      description: "LEBARA GER",
      reference: "r",
    });
  });

  it("takes the booking day without a purchase day, and skips rows without a day or amount", () => {
    expect(mapCardTransaction({ ...base, transaktionDate: "2026-10-32" })!.day).toBe("2026-11-01");
    expect(mapCardTransaction({ ...base, transaktionDate: undefined })!.day).toBe("2026-11-01");
    expect(mapCardTransaction({ ...base, transaktionDate: null, bookingDate: null })).toBeNull();
    expect(mapCardTransaction({ ...base, transactionValueInEUR: null, transactionValue: null })).toBeNull();
    expect(mapCardTransaction({ ...base, bookingStatus: "NOTBOOKED" })).toBeNull();
    expect(mapCardTransaction(null)).toBeNull();
  });

  it("signs the amount by its direction, in euros", () => {
    expect(mapCardTransaction({ ...base, transactionValueInEUR: { value: "4.99" } })!.amountCents).toBe(-499);
    expect(mapCardTransaction({ ...base, transactionDirection: "IN", transactionValueInEUR: { value: "-4.99" } })!.amountCents).toBe(499);
    expect(mapCardTransaction({ ...base, transactionDirection: undefined, transactionValueInEUR: { value: "-4.99" } })!.amountCents).toBe(-499);
    expect(mapCardTransaction({ ...base, transactionValueInEUR: undefined, transactionValue: { value: "-7.50", unit: "EUR" } })!.amountCents).toBe(-750);
    const foreign = mapCardTransaction({
      ...base,
      remittanceInfo: ["UBER *TRIP"],
      transactionValueInEUR: { value: "-11.52", unit: "EUR" },
      transactionValue: { value: "-12.34", unit: "USD" },
    })!;
    expect([foreign.amountCents, foreign.payee, foreign.description]).toEqual([-1152, "UBER *TRIP", "12.34 USD"]);
    const both = mapCardTransaction({ ...base, transactionValue: { value: "-12.34", unit: "usd" } })!;
    expect(both.description).toBe("LEBARA GER 12.34 USD");
  });

  it("names the bill and refunds by their category, never twice", () => {
    const bill = { ...base, remittanceInfo: ["Visa-Kartenabrechnung"], categoryDisplayName: "Visa-Kartenabrechnung", transactionDirection: "IN" };
    expect(mapCardTransaction(bill)).toMatchObject({ payee: "Visa-Kartenabrechnung", description: "", amountCents: 499 });
    expect(mapCardTransaction({ ...bill, remittanceInfo: [] })).toMatchObject({ payee: "Visa-Kartenabrechnung", description: "" });
    expect(mapCardTransaction({ ...base, remittanceInfo: ["AMAZON EU"], categoryDisplayName: "Gutschrift" })).toMatchObject({
      payee: "AMAZON EU",
      description: "Gutschrift",
    });
    expect(mapCardTransaction({ ...base, remittanceInfo: ["SHOP"] })!.description).toBe("");
    const long = mapCardTransaction({ ...base, remittanceInfo: ["x".repeat(300), "y".repeat(800)] })!;
    expect([long.payee.length, long.description.length]).toEqual([200, 500]);
  });
});

describe("a sync's account", () => {
  it("is the one asked for, of this family only", async () => {
    const { db, call, f, family } = await linked();
    const other = makeUser(db, { email: "other@test" });
    const otherFamily = makeFamily(db, other.id);
    expect((await call("POST", `/families/${otherFamily.id}/finance/accounts/giro/bank/sync`, {})).status).toBe(404);
    expect((await call("POST", `${f}/accounts/nope/bank/sync`, {})).status).toBe(404);
    expect(db.select().from(finBankSyncs).where(and(eq(finBankSyncs.familyId, family.id))).all()).toHaveLength(0);
  });
});

describe("the migration of the sync floor (drizzle/0023)", () => {
  it("gives links synced before their last booking day as the floor", () => {
    const dir = mkdtempSync(join(tmpdir(), "ohana-migrations-"));
    try {
      const src = resolve(__dirname, "../drizzle");
      cpSync(src, dir, { recursive: true });
      const journalPath = join(dir, "meta/_journal.json");
      const journal = JSON.parse(readFileSync(journalPath, "utf8")) as { entries: { tag: string }[] };
      const idx = journal.entries.findIndex((e) => e.tag === "0023_bank_synced_from");
      expect(idx).toBeGreaterThan(0);
      writeFileSync(journalPath, JSON.stringify({ ...journal, entries: journal.entries.slice(0, idx) }));

      const sqlite = new Database(":memory:");
      sqlite.pragma("foreign_keys = ON");
      const db = drizzle(sqlite, { schema });
      migrate(db, { migrationsFolder: dir });
      const run = (q: string) => sqlite.prepare(q).run();
      run("insert into families (id, name, created_at, updated_at) values ('f1', 'A', 0, 0)");
      run("insert into fin_accounts (family_id, id, name, color) values ('f1', 'giro', 'Giro', '#3b82f6'), ('f1', 'new', 'New', '#3b82f6')");
      run(`insert into fin_bank_links (family_id, account_id, provider, credentials, synced_through, created_at, updated_at)
           values ('f1', 'giro', 'comdirect', 'v1:x', '2026-10-20', 0, 0), ('f1', 'new', 'comdirect', 'v1:x', null, 0, 0)`);
      migrate(db, { migrationsFolder: src });

      const links = db.select().from(finBankLinks).all().sort((a, b) => a.accountId.localeCompare(b.accountId));
      expect(links.map((l) => [l.accountId, l.syncedThrough, l.syncedFrom])).toEqual([
        ["giro", "2026-10-20", "2026-10-20"],
        ["new", null, null],
      ]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("the migration of the transactions' source (drizzle/0026)", () => {
  it("takes imported rows of a linked account added after it was linked for the bank's", () => {
    const dir = mkdtempSync(join(tmpdir(), "ohana-migrations-"));
    try {
      const src = resolve(__dirname, "../drizzle");
      cpSync(src, dir, { recursive: true });
      const journalPath = join(dir, "meta/_journal.json");
      const journal = JSON.parse(readFileSync(journalPath, "utf8")) as { entries: { tag: string }[] };
      const idx = journal.entries.findIndex((e) => e.tag === "0026_bank_full_sync");
      expect(idx).toBeGreaterThan(0);
      writeFileSync(journalPath, JSON.stringify({ ...journal, entries: journal.entries.slice(0, idx) }));

      const sqlite = new Database(":memory:");
      sqlite.pragma("foreign_keys = ON");
      const db = drizzle(sqlite, { schema });
      migrate(db, { migrationsFolder: dir });
      const run = (q: string) => sqlite.prepare(q).run();
      run("insert into families (id, name, created_at, updated_at) values ('f1', 'A', 0, 0)");
      run("insert into fin_accounts (family_id, id, name, color) values ('f1', 'giro', 'Giro', '#3b82f6'), ('f1', 'cash', 'Cash', '#3b82f6')");
      run(`insert into fin_bank_links (family_id, account_id, provider, credentials, created_at, updated_at)
           values ('f1', 'giro', 'comdirect', 'v1:x', 1000, 1000)`);
      run(`insert into fin_transactions (family_id, id, day, amount_cents, import_hash, account_id, created_at) values
           ('f1', 'typed', '2026-10-01', -100, null, 'giro', 2000),
           ('f1', 'csv-before-link', '2026-10-02', -200, 'h1', 'giro', 500),
           ('f1', 'synced', '2026-10-03', -300, 'h2', 'giro', 2000),
           ('f1', 'csv-unlinked', '2026-10-04', -400, 'h3', 'cash', 2000)`);
      migrate(db, { migrationsFolder: src });

      const rows = db.select().from(finTransactions).all().sort((a, b) => a.day.localeCompare(b.day));
      expect(rows.map((t) => [t.id, t.source])).toEqual([
        ["typed", "manual"],
        ["csv-before-link", "csv"],
        ["synced", "bank"],
        ["csv-unlinked", "csv"],
      ]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
