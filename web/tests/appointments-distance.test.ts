import { describe, expect, it } from "vitest";
import { haversineKm, formatDistanceKm } from "@/lib/appointments/distance";

describe("haversineKm", () => {
  it("is ~0 for identical points", () => {
    expect(haversineKm(48.1, 11.5, 48.1, 11.5)).toBeCloseTo(0, 5);
  });
  it("computes a known distance (Munich centre → practice ~2.6km)", () => {
    // 48.1068,11.4456 (search centre) → 48.1165,11.4772 (practice)
    const km = haversineKm(48.1068, 11.4456, 48.1165, 11.4772);
    expect(km).toBeGreaterThan(2);
    expect(km).toBeLessThan(3);
  });
});

describe("formatDistanceKm", () => {
  it("uses one decimal below 10km", () => {
    expect(formatDistanceKm(2.63, "en")).toBe("2.6 km");
  });
  it("uses a comma decimal for de locale", () => {
    expect(formatDistanceKm(2.63, "de")).toBe("2,6 km");
  });
  it("uses no decimals at/above 10km", () => {
    expect(formatDistanceKm(12.4, "en")).toBe("12 km");
  });
});
