import { describe, expect, it } from "vitest";
import { computeNextRunAt, cronMatches } from "@/lib/appointments/scheduling";

describe("computeNextRunAt", () => {
  const from = new Date("2026-07-01T12:00:00Z");

  it("adds the minutes interval with no jitter when disabled", () => {
    process.env.SCHEDULE_JITTER_PERCENT = "0";
    const next = computeNextRunAt({ scheduleType: "MINUTES", scheduleMinutes: 30 }, from);
    expect(next?.getTime()).toBe(from.getTime() + 30 * 60 * 1000);
  });

  it("hourly and daily map to fixed intervals", () => {
    process.env.SCHEDULE_JITTER_PERCENT = "0";
    expect(computeNextRunAt({ scheduleType: "HOURLY", scheduleMinutes: null }, from)?.getTime()).toBe(
      from.getTime() + 60 * 60 * 1000,
    );
    expect(computeNextRunAt({ scheduleType: "DAILY", scheduleMinutes: null }, from)?.getTime()).toBe(
      from.getTime() + 24 * 60 * 60 * 1000,
    );
  });

  it("applies symmetric jitter within bounds", () => {
    process.env.SCHEDULE_JITTER_PERCENT = "10";
    const base = 30 * 60 * 1000;
    const low = computeNextRunAt({ scheduleType: "MINUTES", scheduleMinutes: 30 }, from, () => 0);
    const high = computeNextRunAt({ scheduleType: "MINUTES", scheduleMinutes: 30 }, from, () => 1);
    expect(low!.getTime() - from.getTime()).toBeCloseTo(base * 0.9, -3);
    expect(high!.getTime() - from.getTime()).toBeCloseTo(base * 1.1, -3);
  });

  it("returns null for CRON", () => {
    expect(computeNextRunAt({ scheduleType: "CRON", scheduleMinutes: null }, from)).toBeNull();
  });
});

describe("cronMatches", () => {
  it("matches every-15-minutes", () => {
    expect(cronMatches("*/15 * * * *", new Date("2026-07-01T12:15:00"))).toBe(true);
    expect(cronMatches("*/15 * * * *", new Date("2026-07-01T12:16:00"))).toBe(false);
  });
  it("matches specific hour and minute", () => {
    expect(cronMatches("30 8 * * *", new Date("2026-07-01T08:30:00"))).toBe(true);
    expect(cronMatches("30 8 * * *", new Date("2026-07-01T09:30:00"))).toBe(false);
  });
  it("rejects malformed expressions", () => {
    expect(cronMatches("nonsense", new Date())).toBe(false);
  });
});
