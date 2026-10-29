// Port of findmyappointment's notifications tests, plus notifyRun against the database
// (change detection, notify-only-earlier with earliest_seen advanced only after a send).
import { eq } from "drizzle-orm";
import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import * as schema from "@/lib/db/schema";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";
import { makeResult, makeRun, makeSearch } from "@/lib/test/appointments";
import {
  buildMessage,
  buildSlotList,
  changedDoctors,
  earliestByDoctor,
  notifyRun,
  recordBeatingDoctors,
  renderEmailBody,
  type NotifyMessage,
  type SlotDetail,
} from "@/lib/appointments/notify";
import { createChannel } from "@/lib/notifications/channels";
import type { Channel, Message } from "@/lib/notifications";
import { getDictionary } from "@/lib/i18n/dictionary";
import { translate, type TVars } from "@/lib/i18n/translate";

const d = (s: string) => new Date(s);
const tFor = (loc: "en" | "de") => (key: string, vars?: TVars) => translate(getDictionary(loc), key, vars);
const t = tFor("en");
const URL = "https://ohana.test/f/fam/appointments/sid";

describe("earliestByDoctor", () => {
  it("keeps the earliest slot per doctor", () => {
    const map = earliestByDoctor([
      { doctorName: "A", slotDatetime: d("2026-07-10T10:00:00Z") },
      { doctorName: "A", slotDatetime: d("2026-07-08T10:00:00Z") },
      { doctorName: "B", slotDatetime: d("2026-07-09T10:00:00Z") },
    ]);
    expect(map.get("A")).toEqual(d("2026-07-08T10:00:00Z"));
    expect(map.get("B")).toEqual(d("2026-07-09T10:00:00Z"));
  });

  it("filters out slots at or before `after`", () => {
    const map = earliestByDoctor([{ doctorName: "A", slotDatetime: d("2026-07-01T00:00:00Z") }], d("2026-07-05T00:00:00Z"));
    expect(map.size).toBe(0);
  });
});

describe("changedDoctors", () => {
  it("reports newly available and moved-earlier doctors only", () => {
    const current = new Map([
      ["A", d("2026-07-08T10:00:00Z")], // moved earlier
      ["B", d("2026-07-09T10:00:00Z")], // new
      ["C", d("2026-07-12T10:00:00Z")], // later → not reported
    ]);
    const previous = new Map([
      ["A", d("2026-07-10T10:00:00Z")],
      ["C", d("2026-07-11T10:00:00Z")],
    ]);
    expect([...changedDoctors(current, previous).keys()].sort()).toEqual(["A", "B"]);
  });
});

const slot = (over: Partial<SlotDetail> = {}): SlotDetail => ({
  resultId: 1,
  doctorName: "Dr A",
  practiceName: "Praxis",
  motiveLabel: "Erstberatung",
  slotDatetime: d("2026-07-10T10:00:00Z"),
  bookingUrl: "https://www.doctolib.de/x",
  isNextSlot: false,
  ...over,
});

describe("buildMessage", () => {
  it("deep-links to the specific slot page when exactly one", () => {
    const { url } = buildMessage(t, "S", URL, new Map([["A", d("2026-07-08T10:00:00Z")]]), [slot({ resultId: 42, doctorName: "A" })]);
    expect(url).toBe(`${URL}/slots/42`);
  });

  it("falls back to the search page for multiple slots", () => {
    const changed = new Map([["A", d("2026-07-08T10:00:00Z")], ["B", d("2026-07-09T10:00:00Z")]]);
    const { url } = buildMessage(t, "S", URL, changed, [slot({ resultId: 42 }), slot({ resultId: 43, doctorName: "B" })]);
    expect(url).toBe(URL);
  });

  it("translates and pluralizes the title", () => {
    const one = buildMessage(t, "Zahnarzt", URL, new Map([["A", d("2026-07-08T10:00:00Z")]]), [slot()]);
    expect(one.title).toBe("1 new appointment for Zahnarzt");
    const de = buildMessage(tFor("de"), "Zahnarzt", URL, new Map([["A", d("2026-07-08T10:00:00Z")], ["B", d("2026-07-09T10:00:00Z")]]), [slot(), slot({ resultId: 2 })]);
    expect(de.title).toBe("2 neue Termine für Zahnarzt");
  });
});

describe("recordBeatingDoctors", () => {
  it("reports all when there is no record and seeds the min", () => {
    const current = new Map([["A", d("2026-07-10T10:00:00Z")], ["B", d("2026-07-08T10:00:00Z")]]);
    const { beaters, newRecord } = recordBeatingDoctors(current, null);
    expect(beaters.size).toBe(2);
    expect(newRecord).toEqual(d("2026-07-08T10:00:00Z"));
  });

  it("reports only doctors beating the record and advances it", () => {
    const current = new Map([["A", d("2026-07-09T10:00:00Z")], ["B", d("2026-07-15T10:00:00Z")]]);
    const { beaters, newRecord } = recordBeatingDoctors(current, d("2026-07-10T10:00:00Z"));
    expect([...beaters.keys()]).toEqual(["A"]);
    expect(newRecord).toEqual(d("2026-07-09T10:00:00Z"));
  });
});

describe("buildSlotList", () => {
  it("keeps only changed doctors and sorts by datetime", () => {
    const results = [
      slot({ doctorName: "Dr A", slotDatetime: d("2026-07-12T10:00:00Z"), resultId: 10 }),
      slot({ doctorName: "Dr A", slotDatetime: d("2026-07-08T10:00:00Z"), resultId: 11 }),
      slot({ doctorName: "Dr B", slotDatetime: d("2026-07-09T10:00:00Z"), resultId: 12 }),
      slot({ doctorName: "Dr C", slotDatetime: d("2026-07-05T10:00:00Z"), resultId: 13 }),
    ];
    const changed = new Map([["Dr A", d("2026-07-08T10:00:00Z")], ["Dr B", d("2026-07-09T10:00:00Z")]]);
    expect(buildSlotList(results, changed).map((s) => [s.doctorName, s.slotDatetime.toISOString()])).toEqual([
      ["Dr A", "2026-07-08T10:00:00.000Z"],
      ["Dr B", "2026-07-09T10:00:00.000Z"],
      ["Dr A", "2026-07-12T10:00:00.000Z"],
    ]);
  });
});

describe("renderEmailBody", () => {
  const msg: NotifyMessage = {
    title: "2 new appointments for Zahnarzt",
    body: "ignored",
    url: URL,
    searchUrl: URL,
    slots: [
      slot({ doctorName: "Dr <A>", bookingUrl: "https://www.doctolib.de/a", resultId: 1 }),
      slot({ doctorName: "Dr B", isNextSlot: true, bookingUrl: "https://www.doctolib.de/b", resultId: 2 }),
    ],
  };

  it("html links every slot to its booking url and escapes names", () => {
    const { html } = renderEmailBody(t, msg);
    expect(html).toContain('href="https://www.doctolib.de/a"');
    expect(html).toContain('href="https://www.doctolib.de/b"');
    expect(html).toContain("Dr &lt;A&gt;");
    expect(html).toContain("next available");
    expect(html).toContain("Open in Ohana");
    expect(html).toContain(`href="${URL}"`);
  });

  it("text lists each slot's Ohana page and booking url", () => {
    const { text } = renderEmailBody(t, msg);
    expect(text).toContain("https://www.doctolib.de/a");
    expect(text).toContain(`${URL}/slots/1`);
    expect(text).toContain(`${URL}/slots/2`);
  });

  it("renders German strings when given a German translator", () => {
    const { html, text } = renderEmailBody(tFor("de"), msg);
    expect(html).toContain("Alle Ergebnisse ansehen");
    expect(html).toContain("In Ohana öffnen");
    expect(text).toContain("nächster freier Termin");
  });
});

describe("notifyRun", () => {
  let db: Db;
  let family: { id: string };
  let channelId: string;
  const editor = () => db.select().from(schema.users).get()!;
  const sent: { channel: Channel; msg: Message }[] = [];
  const ok = async (channel: Channel, msg: Message) => void sent.push({ channel, msg });
  const failing = async () => {
    throw new Error("down");
  };
  const at = (days: number) => new Date(NOW.getTime() + days * 24 * 60 * 60 * 1000);

  beforeEach(() => {
    db = createTestDb();
    const user = makeUser(db);
    family = makeFamily(db, user.id);
    channelId = createChannel(db, { id: editor().id }, family.id, { name: "Phone", provider: "PUSHBULLET", token: "tok", target: "", smtpHost: "", smtpPort: 465, smtpUsername: "", smtpFrom: "", enabled: true }, NOW).id;
    sent.length = 0;
  });

  function search(over: Partial<typeof schema.apptSearches.$inferInsert> = {}) {
    const s = makeSearch(db, family.id, { name: "Derm", ...over });
    db.insert(schema.apptSearchChannels).values({ searchId: s.id, channelId }).run();
    return s;
  }

  it("notifies on a new doctor, deep-links and sends the opened token", async () => {
    const s = search();
    const run = makeRun(db, s.id);
    const r = makeResult(db, run.id, { doctorName: "Dr A", slotDatetime: at(2) });
    expect(await notifyRun(db, run.id, { send: ok, now: NOW })).toBe(true);
    expect(sent).toHaveLength(1);
    expect(sent[0].channel.token).toBe("tok");
    expect(sent[0].msg.url).toMatch(new RegExp(`/f/${family.id}/appointments/${s.id}/slots/${r.id}$`));
    expect(sent[0].msg.email?.html).toContain("Dr A");
    expect(db.select().from(schema.apptRuns).where(eq(schema.apptRuns.id, run.id)).get()!.notified).toBe(true);
  });

  it("stays quiet when nothing changed since the previous run", async () => {
    const s = search();
    const r1 = makeRun(db, s.id, { startedAt: at(0) });
    makeResult(db, r1.id, { doctorName: "Dr A", slotDatetime: at(2) });
    const r2 = makeRun(db, s.id, { startedAt: new Date(NOW.getTime() + 60_000) });
    makeResult(db, r2.id, { doctorName: "Dr A", slotDatetime: at(3) }); // later → no news
    expect(await notifyRun(db, r2.id, { send: ok, now: NOW })).toBe(false);
    expect(sent).toHaveLength(0);
  });

  it("sends nothing when the search has no channels", async () => {
    const s = makeSearch(db, family.id);
    const run = makeRun(db, s.id);
    makeResult(db, run.id);
    expect(await notifyRun(db, run.id, { send: ok, now: NOW })).toBe(false);
    expect(sent).toHaveLength(0);
  });

  it("notify-only-earlier: seeds earliest_seen, then notifies only for a better slot", async () => {
    const s = search({ notifyOnlyEarlier: true });
    const r1 = makeRun(db, s.id);
    makeResult(db, r1.id, { doctorName: "Dr A", slotDatetime: at(5) });
    expect(await notifyRun(db, r1.id, { send: ok, now: NOW })).toBe(true);
    const seen = () => db.select().from(schema.apptSearches).where(eq(schema.apptSearches.id, s.id)).get()!.earliestSeen;
    expect(seen()).toEqual(at(5));

    const r2 = makeRun(db, s.id, { startedAt: new Date(NOW.getTime() + 60_000) });
    makeResult(db, r2.id, { doctorName: "Dr B", slotDatetime: at(6) }); // new doctor, but later
    expect(await notifyRun(db, r2.id, { send: ok, now: NOW })).toBe(false);

    const r3 = makeRun(db, s.id, { startedAt: new Date(NOW.getTime() + 120_000) });
    makeResult(db, r3.id, { doctorName: "Dr B", slotDatetime: at(4) });
    expect(await notifyRun(db, r3.id, { send: ok, now: NOW })).toBe(true);
    expect(seen()).toEqual(at(4));
  });

  it("notify-only-earlier: a failed delivery leaves earliest_seen untouched", async () => {
    const s = search({ notifyOnlyEarlier: true, earliestSeen: at(5) });
    const run = makeRun(db, s.id);
    makeResult(db, run.id, { doctorName: "Dr A", slotDatetime: at(3) });
    expect(await notifyRun(db, run.id, { send: failing, now: NOW })).toBe(false);
    expect(db.select().from(schema.apptSearches).where(eq(schema.apptSearches.id, s.id)).get()!.earliestSeen).toEqual(at(5));
    expect(await notifyRun(db, run.id, { send: ok, now: NOW })).toBe(true); // next time it goes out
  });

  it("notify-only-earlier: a record in the past counts as none", async () => {
    const s = search({ notifyOnlyEarlier: true, earliestSeen: at(-1) });
    const run = makeRun(db, s.id);
    makeResult(db, run.id, { doctorName: "Dr A", slotDatetime: at(9) });
    expect(await notifyRun(db, run.id, { send: ok, now: NOW })).toBe(true);
  });
});
