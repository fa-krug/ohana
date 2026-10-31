// GET /api/v1/server's data and DISABLED_MODULES: the family API's 404, the assistant's tools.

import { afterEach, describe, expect, it } from "vitest";
import { createFamilyApi } from "@/lib/api/family-api";
import { handleDisabledModules } from "@/lib/api/disabled-modules";
import { createToken } from "@/lib/auth/tokens";
import { handleFinance } from "@/lib/finance/finance";
import { toolsFor } from "@/lib/assistant/tools";
import { API_VERSION, enabledModules, moduleOfFamilyPath, serverInfo, serverVersion } from "@/lib/server-info";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";
import pkg from "../package.json";

afterEach(() => {
  delete process.env.DISABLED_MODULES;
});

describe("server info", () => {
  it("lists every module by default", () => {
    expect(enabledModules({})).toEqual(["calendar", "finance", "meals", "appointments", "assistant"]);
  });

  it("leaves out the turned-off modules, never the calendar, ignoring unknown names", () => {
    expect(enabledModules({ DISABLED_MODULES: " Appointments, assistant ,calendar,unknown" })).toEqual(["calendar", "finance", "meals"]);
  });

  it("reports the version from OHANA_VERSION, else package.json", () => {
    expect(serverVersion({})).toBe(pkg.version);
    expect(serverVersion({ OHANA_VERSION: "1.2.3" })).toBe("1.2.3");
    expect(serverInfo({ OHANA_VERSION: "1.2.3", DISABLED_MODULES: "meals" })).toEqual({
      name: "Ohana",
      version: "1.2.3",
      apiVersion: API_VERSION,
      modules: ["calendar", "finance", "appointments", "assistant"],
    });
  });

  it("knows which module a family API path belongs to", () => {
    expect(moduleOfFamilyPath(["finance", "transactions"])).toBe("finance");
    expect(moduleOfFamilyPath(["meals", "plan"])).toBe("meals");
    expect(moduleOfFamilyPath(["recipes"])).toBe("meals");
    expect(moduleOfFamilyPath(["appointments"])).toBe("appointments");
    expect(moduleOfFamilyPath(["ai", "chats"])).toBe("assistant");
    expect(moduleOfFamilyPath(["agent"])).toBe("assistant");
    expect(moduleOfFamilyPath(["entries"])).toBeNull();
    expect(moduleOfFamilyPath([])).toBeNull();
  });
});

describe("turned-off modules", () => {
  function setup() {
    const db = createTestDb();
    const user = makeUser(db, { email: "anna@test" });
    const family = makeFamily(db, user.id);
    const token = createToken(db, { userId: user.id, kind: "api" }, NOW).token;
    const api = createFamilyApi([handleDisabledModules, handleFinance], { db, now: () => NOW });
    const get = (path: string) =>
      api(new Request(`http://ohana.test/api/v1/families/${family.id}${path}`, { headers: { authorization: `Bearer ${token}` } }));
    return { get };
  }

  it("answers their routes with 404", async () => {
    const { get } = setup();
    expect((await get("/finance")).status).toBe(200);
    process.env.DISABLED_MODULES = "finance";
    const res = await get("/finance");
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "This module is turned off on this server" });
  });

  it("takes their tools from the assistant", () => {
    const names = () => toolsFor({ writes: true, search: false }).map((t) => t.function.name);
    const all = names();
    expect(all.some((n) => n.includes("transaction"))).toBe(true);
    process.env.DISABLED_MODULES = "finance,meals,appointments";
    const fewer = names();
    expect(fewer.length).toBeLessThan(all.length);
    expect(fewer.some((n) => n.includes("transaction"))).toBe(false);
    expect(fewer.some((n) => n.includes("recipe"))).toBe(false);
    // The calendar's tools stay.
    expect(fewer.length).toBeGreaterThan(0);
  });
});
