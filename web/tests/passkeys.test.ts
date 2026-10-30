import { eq } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { passkeyCredentials, users } from "@/lib/db/schema";
import {
  beginPasskeyLogin,
  beginPasskeyRegistration,
  completePasskeyLogin,
  completePasskeyRegistration,
} from "@/lib/auth/passkey-auth";
import { beginAddPasskey, completeAddPasskey, deletePasskey, listPasskeys } from "@/lib/auth/passkey-management";
import { createInvite } from "@/lib/families/invites";
import { getRole } from "@/lib/families/roles";
import { Authenticator } from "@/lib/test/authenticator";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

const ORIGIN = "http://localhost:3000";
const RP = "localhost";

describe("passkeys (with a software authenticator)", () => {
  it("create the first account, which signs in without typing a name", async () => {
    const db = createTestDb();
    const key = new Authenticator(ORIGIN);
    const reg = await beginPasskeyRegistration(db, { email: "a@x.test", name: "Sascha" }, RP, NOW);
    const user = await completePasskeyRegistration(
      db,
      { responseJson: JSON.stringify(await key.register(reg.options)), deviceName: "Test" },
      reg.ceremony,
      RP,
      NOW,
    );
    expect(user).toMatchObject({ email: "a@x.test", name: "Sascha", isAdmin: true, password: "" });
    // A second "first run" is refused.
    await expect(beginPasskeyRegistration(db, { email: "b@x.test", name: "" }, RP, NOW)).rejects.toMatchObject({ status: 409 });

    const login = await beginPasskeyLogin(db, {}, RP);
    expect(login.options.allowCredentials ?? []).toHaveLength(0);
    const signedIn = await completePasskeyLogin(
      db,
      { responseJson: JSON.stringify(await key.signIn(login.options)) },
      login.ceremony,
      RP,
      NOW,
    );
    expect(signedIn.id).toBe(user.id);
    expect(listPasskeys(db, user.id)[0].lastUsedAt).toEqual(NOW);
  });

  it("create accounts from invites, with the invite's role", async () => {
    const db = createTestDb();
    const editor = makeUser(db);
    const family = makeFamily(db, editor.id);
    const { code } = createInvite(db, { id: editor.id }, family.id, "viewer", NOW);
    const key = new Authenticator(ORIGIN);
    const reg = await beginPasskeyRegistration(db, { email: "kid@x.test", name: "Kid", inviteCode: code }, RP, NOW);
    const user = await completePasskeyRegistration(
      db,
      { responseJson: JSON.stringify(await key.register(reg.options)), deviceName: "" },
      reg.ceremony,
      RP,
      NOW,
    );
    expect(user).toMatchObject({ isAdmin: false, lastFamilyId: family.id });
    expect(getRole(db, family.id, user.id)).toBe("viewer");
  });

  it("are refused for the wrong user or a wrong origin", async () => {
    const db = createTestDb();
    const key = new Authenticator(ORIGIN);
    const reg = await beginPasskeyRegistration(db, { email: "a@x.test", name: "" }, RP, NOW);
    await completePasskeyRegistration(db, { responseJson: JSON.stringify(await key.register(reg.options)), deviceName: "" }, reg.ceremony, RP, NOW);
    makeUser(db, { email: "b@x.test" });
    await expect(beginPasskeyLogin(db, { email: "b@x.test" }, RP)).rejects.toThrow(/No passkeys/);

    const login = await beginPasskeyLogin(db, { email: "a@x.test" }, RP);
    const evil = await key.signIn(login.options, "https://evil.test");
    await expect(
      completePasskeyLogin(db, { responseJson: JSON.stringify(evil) }, login.ceremony, RP, NOW),
    ).rejects.toThrow(/verification failed/);
    // A ceremony for another user doesn't accept this passkey.
    await expect(
      completePasskeyLogin(db, { responseJson: JSON.stringify(await key.signIn(login.options)) }, { ...login.ceremony, email: "b@x.test" }, RP, NOW),
    ).rejects.toThrow(/does not belong/);
  });

  it("are added to an account and finish onboarding; the last one stays without a password", async () => {
    const db = createTestDb();
    const user = makeUser(db, { onboardingStep: "SET_CREDENTIALS" });
    const key = new Authenticator(ORIGIN);
    const add = await beginAddPasskey(db, user.id, RP);
    const dto = await completeAddPasskey(
      db,
      { userId: user.id, responseJson: JSON.stringify(await key.register(add.options)), deviceName: "Phone" },
      add.ceremony,
      RP,
      NOW,
    );
    expect(dto.deviceName).toBe("Phone");
    expect(db.select().from(users).where(eq(users.id, user.id)).get()!.onboardingStep).toBe("COMPLETED");
    expect(() => deletePasskey(db, user.id, dto.id)).toThrow(/only passkey/);
    expect(db.select().from(passkeyCredentials).all()).toHaveLength(1);
  });
});
