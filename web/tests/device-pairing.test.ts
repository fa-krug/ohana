import { describe, expect, it } from "vitest";
import { deviceTokenName, pairDevice, safeNext, validPairState } from "@/lib/auth/device-pairing";
import { findToken, listTokens } from "@/lib/auth/tokens";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeUser } from "@/lib/test/factories";

describe("device pairing", () => {
  it("hands the app a new API token named after the device, with the state echoed", () => {
    const db = createTestDb();
    const user = makeUser(db);
    const state = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
    const { callbackUrl } = pairDevice(db, user.id, { state, deviceName: "Sascha’s  iPhone" }, NOW);
    const url = new URL(callbackUrl);
    expect(`${url.protocol}//${url.host}${url.pathname}`).toBe("ohana://auth-callback");
    expect(url.searchParams.get("state")).toBe(state);
    const token = url.searchParams.get("token")!;
    expect(token.startsWith("ohana_")).toBe(true);
    expect(findToken(db, token, "api", NOW)?.user.id).toBe(user.id);
    expect(listTokens(db, user.id, "api").map((t) => t.name)).toEqual(["Sascha’s iPhone (app)"]);
  });

  it("refuses a missing or odd state", () => {
    const db = createTestDb();
    const user = makeUser(db);
    for (const state of ["", "short", "has spaces in it", "x".repeat(200), "a&b=c-d-e-f"]) {
      expect(validPairState(state)).toBe(false);
      expect(() => pairDevice(db, user.id, { state }, NOW)).toThrow();
    }
  });

  it("names a nameless device", () => {
    expect(deviceTokenName(undefined)).toBe("Ohana app");
    expect(deviceTokenName("   ")).toBe("Ohana app");
  });

  it("follows only paths of this site after signing in", () => {
    expect(safeNext("/device/pair?state=abc")).toBe("/device/pair?state=abc");
    expect(safeNext("//evil.example/x")).toBeNull();
    expect(safeNext("https://evil.example")).toBeNull();
    expect(safeNext("/\\evil.example")).toBeNull();
    expect(safeNext(undefined)).toBeNull();
  });
});
