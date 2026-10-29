import { describe, expect, it } from "vitest";
import { hashPassword } from "@/lib/auth/password";
import { loginWithPassword } from "@/lib/auth/login";
import { MAX_FAILURES, WINDOW_MS, deleteOldRateLimits } from "@/lib/auth/rate-limit";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeUser } from "@/lib/test/factories";

describe("password sign-in rate limit", () => {
  it("blocks a sign-in name after too many failures, until the window passes", async () => {
    const db = createTestDb();
    makeUser(db, { email: "a@x.test", password: await hashPassword("Tr0ub4dour&3") });
    for (let i = 0; i < MAX_FAILURES; i++) {
      await expect(loginWithPassword(db, { email: "a@x.test", password: "wrong" }, NOW)).rejects.toMatchObject({ status: 401 });
    }
    // Even the right password is refused now.
    await expect(loginWithPassword(db, { email: "a@x.test", password: "Tr0ub4dour&3" }, NOW)).rejects.toMatchObject({ status: 429 });
    // Unknown names count too, so they can't be probed endlessly.
    await expect(loginWithPassword(db, { email: "b@x.test", password: "x" }, NOW)).rejects.toMatchObject({ status: 401 });

    const later = new Date(NOW.getTime() + WINDOW_MS);
    const user = await loginWithPassword(db, { email: "a@x.test", password: "Tr0ub4dour&3" }, later);
    expect(user.email).toBe("a@x.test");
    expect(deleteOldRateLimits(db, later)).toBe(2);
  });
});
