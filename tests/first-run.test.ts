import { describe, expect, it } from "vitest";
import { hasAnyUser, registerFirstUser } from "@/lib/auth/first-run";
import { createTestDb } from "@/lib/test/db";
import { NOW } from "@/lib/test/factories";

describe("first run", () => {
  it("creates the first account as an administrator, once", async () => {
    const db = createTestDb();
    expect(hasAnyUser(db)).toBe(false);
    const user = await registerFirstUser(db, { email: "a@x.test", name: "Sascha", password: "Tr0ub4dour&3" }, NOW);
    expect(user).toMatchObject({ isAdmin: true, name: "Sascha", onboardingStep: "ADD_PASSKEY" });
    await expect(
      registerFirstUser(db, { email: "b@x.test", name: "", password: "Tr0ub4dour&3" }, NOW),
    ).rejects.toMatchObject({ status: 409 });
  });
});
