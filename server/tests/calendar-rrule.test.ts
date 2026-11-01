// Repeat rules (lib/calendar/rrule.ts): checking RRULE values and expanding them on plain days,
// against RFC 5545's examples where they are date-only.

import { describe, expect, it } from "vitest";
import { expandRule, isRuleOccurrence, normalizeRrule, parseRrule, withEnd } from "@/lib/calendar/rrule";

const x = (rule: string, start: string, from: string, to: string, limit?: number) =>
  expandRule(parseRrule(rule), start, from, to, limit);

describe("checking rules", () => {
  it("stores them trimmed and upper-cased", () => {
    expect(normalizeRrule("  freq=weekly;byday=mo,we ")).toBe("FREQ=WEEKLY;BYDAY=MO,WE");
    expect(normalizeRrule("FREQ=MONTHLY;BYDAY=-1FR")).toBe("FREQ=MONTHLY;BYDAY=-1FR");
    expect(normalizeRrule("FREQ=YEARLY;BYMONTH=11;BYDAY=4TH")).toBe("FREQ=YEARLY;BYMONTH=11;BYDAY=4TH");
    expect(normalizeRrule("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;WKST=SU")).toBe(
      "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;WKST=SU",
    );
  });

  it.each([
    ["", "must not be empty"],
    ["RRULE:FREQ=DAILY", "unknown part"],
    ["INTERVAL=2", "FREQ is required"],
    ["FREQ=HOURLY", "FREQ must be"],
    ["FREQ=DAILY;FREQ=WEEKLY", "twice"],
    ["FREQ=DAILY;COUNT=0", "COUNT"],
    ["FREQ=DAILY;INTERVAL=0", "INTERVAL"],
    ["FREQ=DAILY;UNTIL=20270230", "UNTIL"],
    ["FREQ=DAILY;UNTIL=20270101T000000Z", "UNTIL"],
    ["FREQ=DAILY;COUNT=3;UNTIL=20270101", "COUNT and UNTIL"],
    ["FREQ=WEEKLY;BYDAY=2MO", "ordinals"],
    ["FREQ=MONTHLY;BYDAY=0MO", "BYDAY"],
    ["FREQ=MONTHLY;BYDAY=XX", "BYDAY"],
    ["FREQ=WEEKLY;BYMONTHDAY=1", "BYMONTHDAY"],
    ["FREQ=MONTHLY;BYMONTHDAY=32", "out of range"],
    ["FREQ=MONTHLY;BYYEARDAY=1", "BYYEARDAY"],
    ["FREQ=MONTHLY;BYWEEKNO=1", "BYWEEKNO"],
    ["FREQ=YEARLY;BYWEEKNO=20;BYDAY=1MO", "ordinals"],
    ["FREQ=YEARLY;BYMONTH=13", "out of range"],
    ["FREQ=DAILY;BYSETPOS=1", "BYSETPOS"],
    ["FREQ=DAILY;WKST=XX", "WKST"],
    ["FREQ=DAILY;BYHOUR=9", "unknown part"],
    ["FREQ=DAILY;INTERVAL", "needs a value"],
  ])("refuses %j", (rule, message) => {
    expect(() => normalizeRrule(rule)).toThrow(expect.objectContaining({ status: 400, message: expect.stringContaining(message) }));
  });

  it("refuses what isn't a string", () => {
    expect(() => normalizeRrule(42)).toThrow(expect.objectContaining({ status: 400 }));
  });

  it("changes the end of a rule", () => {
    expect(withEnd("FREQ=WEEKLY;COUNT=10;BYDAY=MO", { until: "2026-12-31" })).toBe("FREQ=WEEKLY;BYDAY=MO;UNTIL=20261231");
    expect(withEnd("FREQ=WEEKLY;UNTIL=20270101", { count: 3 })).toBe("FREQ=WEEKLY;COUNT=3");
  });
});

describe("expanding rules", () => {
  it("repeats daily, every other day, a number of times or until a day", () => {
    expect(x("FREQ=DAILY", "2026-11-01", "2026-11-01", "2026-11-04")).toEqual(["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04"]);
    expect(x("FREQ=DAILY;INTERVAL=2;COUNT=3", "2026-11-01", "2026-01-01", "2027-12-31")).toEqual(["2026-11-01", "2026-11-03", "2026-11-05"]);
    expect(x("FREQ=DAILY;UNTIL=20261103", "2026-11-01", "2026-01-01", "2027-12-31")).toEqual(["2026-11-01", "2026-11-02", "2026-11-03"]);
  });

  it("counts COUNT from DTSTART even when the range starts later", () => {
    expect(x("FREQ=WEEKLY;COUNT=4", "2026-11-02", "2026-11-15", "2026-12-31")).toEqual(["2026-11-16", "2026-11-23"]);
  });

  it("skips ahead to a range far after DTSTART", () => {
    expect(x("FREQ=DAILY", "1990-01-01", "2026-11-01", "2026-11-02")).toEqual(["2026-11-01", "2026-11-02"]);
    expect(x("FREQ=WEEKLY;INTERVAL=3", "2000-01-03", "2026-11-01", "2026-12-31")).toEqual(["2026-11-09", "2026-11-30", "2026-12-21"]);
  });

  it("always starts with DTSTART, even when the rule wouldn't produce it", () => {
    // 2026-11-04 is a Wednesday.
    expect(x("FREQ=WEEKLY;BYDAY=MO;COUNT=3", "2026-11-04", "2026-11-01", "2026-12-31")).toEqual(["2026-11-04", "2026-11-09", "2026-11-16"]);
  });

  it("repeats weekly on several days, every other week, with WKST", () => {
    // RFC 5545: every other week on Tuesday and Thursday, 8 times.
    expect(x("FREQ=WEEKLY;INTERVAL=2;COUNT=8;WKST=SU;BYDAY=TU,TH", "1997-09-02", "1997-01-01", "1998-12-31")).toEqual([
      "1997-09-02", "1997-09-04", "1997-09-16", "1997-09-18", "1997-09-30", "1997-10-02", "1997-10-14", "1997-10-16",
    ]);
    // RFC 5545: WKST changes which weeks count.
    expect(x("FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=MO", "1997-08-05", "1997-01-01", "1998-12-31")).toEqual([
      "1997-08-05", "1997-08-10", "1997-08-19", "1997-08-24",
    ]);
    expect(x("FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=SU", "1997-08-05", "1997-01-01", "1998-12-31")).toEqual([
      "1997-08-05", "1997-08-17", "1997-08-19", "1997-08-31",
    ]);
  });

  it("repeats monthly by day of the month, also from its end, skipping short months", () => {
    expect(x("FREQ=MONTHLY;BYMONTHDAY=-3", "1997-09-28", "1997-01-01", "1998-02-28")).toEqual([
      "1997-09-28", "1997-10-29", "1997-11-28", "1997-12-29", "1998-01-29", "1998-02-26",
    ]);
    expect(x("FREQ=MONTHLY", "2026-01-31", "2026-01-01", "2026-08-31")).toEqual([
      "2026-01-31", "2026-03-31", "2026-05-31", "2026-07-31", "2026-08-31",
    ]);
  });

  it("repeats monthly by weekday ordinals: the first Friday, the last Friday, the second-to-last Monday", () => {
    expect(x("FREQ=MONTHLY;COUNT=4;BYDAY=1FR", "1997-09-05", "1997-01-01", "1998-12-31")).toEqual([
      "1997-09-05", "1997-10-03", "1997-11-07", "1997-12-05",
    ]);
    expect(x("FREQ=MONTHLY;BYDAY=-1FR", "2026-01-30", "2026-01-01", "2026-05-31")).toEqual([
      "2026-01-30", "2026-02-27", "2026-03-27", "2026-04-24", "2026-05-29",
    ]);
    expect(x("FREQ=MONTHLY;BYDAY=-2MO;COUNT=3", "1997-09-22", "1997-01-01", "1998-12-31")).toEqual([
      "1997-09-22", "1997-10-20", "1997-11-17",
    ]);
    // Every other month, the first and last Sunday (RFC 5545).
    expect(x("FREQ=MONTHLY;INTERVAL=2;COUNT=6;BYDAY=1SU,-1SU", "1997-09-07", "1997-01-01", "1998-12-31")).toEqual([
      "1997-09-07", "1997-09-28", "1997-11-02", "1997-11-30", "1998-01-04", "1998-01-25",
    ]);
  });

  it("picks positions with BYSETPOS: the last workday of the month, the third Tue/Wed/Thu", () => {
    expect(x("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", "2026-01-30", "2026-01-01", "2026-06-30")).toEqual([
      "2026-01-30", "2026-02-27", "2026-03-31", "2026-04-30", "2026-05-29", "2026-06-30",
    ]);
    expect(x("FREQ=MONTHLY;COUNT=3;BYDAY=TU,WE,TH;BYSETPOS=3", "1997-09-04", "1997-01-01", "1998-12-31")).toEqual([
      "1997-09-04", "1997-10-07", "1997-11-06",
    ]);
  });

  it("repeats yearly: on the day, in months, by year day, week number and weekday ordinals", () => {
    expect(x("FREQ=YEARLY", "2024-02-29", "2024-01-01", "2033-12-31")).toEqual(["2024-02-29", "2028-02-29", "2032-02-29"]);
    expect(x("FREQ=YEARLY;COUNT=4;BYMONTH=6,7", "1997-06-10", "1997-01-01", "2000-12-31")).toEqual([
      "1997-06-10", "1997-07-10", "1998-06-10", "1998-07-10",
    ]);
    expect(x("FREQ=YEARLY;INTERVAL=3;COUNT=5;BYYEARDAY=1,100,200", "1997-01-01", "1997-01-01", "2010-12-31")).toEqual([
      "1997-01-01", "1997-04-10", "1997-07-19", "2000-01-01", "2000-04-09",
    ]);
    expect(x("FREQ=YEARLY;BYDAY=20MO", "1997-05-19", "1997-01-01", "1999-12-31")).toEqual(["1997-05-19", "1998-05-18", "1999-05-17"]);
    expect(x("FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO", "1997-05-12", "1997-01-01", "1999-12-31")).toEqual(["1997-05-12", "1998-05-11", "1999-05-17"]);
    // Week 1 may start in the year before.
    expect(x("FREQ=YEARLY;BYWEEKNO=1;BYDAY=MO", "1997-12-29", "1997-01-01", "2001-01-31")).toEqual([
      "1997-12-29", "1999-01-04", "2000-01-03", "2001-01-01",
    ]);
    // Thanksgiving: the fourth Thursday of November.
    expect(x("FREQ=YEARLY;BYMONTH=11;BYDAY=4TH", "2026-11-26", "2026-01-01", "2028-12-31")).toEqual(["2026-11-26", "2027-11-25", "2028-11-23"]);
    // Every Thursday in March (RFC 5545).
    expect(x("FREQ=YEARLY;BYMONTH=3;BYDAY=TH", "1997-03-13", "1997-01-01", "1997-12-31")).toEqual(["1997-03-13", "1997-03-20", "1997-03-27"]);
    // The last day of February, every year.
    expect(x("FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=-1", "2024-02-29", "2024-01-01", "2026-12-31")).toEqual(["2024-02-29", "2025-02-28", "2026-02-28"]);
  });

  it("stays bounded: a rule that never matches, a long COUNT, a limit", () => {
    const t0 = Date.now();
    expect(x("FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30", "2026-01-01", "2027-01-01", "9999-12-31")).toEqual([]);
    expect(x("FREQ=DAILY;COUNT=100000", "1700-01-01", "2026-01-01", "2026-01-03")).toEqual([]);
    expect(x("FREQ=DAILY;COUNT=100000", "1900-01-01", "2026-01-01", "2026-01-02")).toEqual(["2026-01-01", "2026-01-02"]);
    expect(x("FREQ=DAILY", "2026-01-01", "2026-01-01", "9999-12-31", 10)).toHaveLength(10);
    expect(Date.now() - t0).toBeLessThan(5000);
  });

  it("tells whether a day is an occurrence", () => {
    const rule = parseRrule("FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4");
    expect(isRuleOccurrence(rule, "2026-11-02", "2026-11-02")).toBe(true);
    expect(isRuleOccurrence(rule, "2026-11-02", "2026-11-11")).toBe(true);
    expect(isRuleOccurrence(rule, "2026-11-02", "2026-11-16")).toBe(false);
    expect(isRuleOccurrence(rule, "2026-11-02", "2026-11-03")).toBe(false);
  });
});
