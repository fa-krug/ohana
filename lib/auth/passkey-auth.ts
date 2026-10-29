import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { passkeyCredentials, users } from "@/lib/db/schema";
import { acceptInvite, validateInvite } from "@/lib/families/invites";
import type { CeremonyState } from "./ceremony";
import { AuthError } from "./errors";
import { hasAnyUser } from "./first-run";
import { assertEmailFree } from "./register";
import type { User } from "./tokens";
import {
  b64urlToBuf,
  getAuthenticationOptions,
  getRegistrationOptions,
  verifyAuthentication,
  verifyRegistration,
} from "./webauthn";

type RegistrationOptions = Awaited<ReturnType<typeof getRegistrationOptions>>;

/** Registration of a new account with a passkey: from an invite link, or the very first
 *  account of a fresh install (which becomes an administrator). */
export async function beginPasskeyRegistration(
  db: Db,
  args: { email: string; name: string; inviteCode?: string },
  rpId: string,
  now: Date,
): Promise<{ options: RegistrationOptions; ceremony: CeremonyState }> {
  const firstRun = !args.inviteCode;
  if (firstRun) {
    if (hasAnyUser(db)) throw new AuthError(409, "Setup has already been completed.");
  } else {
    validateInvite(db, args.inviteCode!, now);
    assertEmailFree(db, args.email);
  }
  const tempUserId = randomUUID();
  const options = await getRegistrationOptions({
    userId: tempUserId,
    userEmail: args.email,
    rpId,
    excludeCredentialIds: [],
  });
  return {
    options,
    ceremony: {
      type: "register",
      challenge: options.challenge,
      email: args.email,
      name: args.name,
      inviteCode: args.inviteCode,
      firstRun,
      tempUserId,
    },
  };
}

export async function completePasskeyRegistration(
  db: Db,
  args: { responseJson: string; deviceName: string },
  ceremony: CeremonyState,
  rpId: string,
  now: Date,
): Promise<User> {
  if (ceremony.type !== "register" || !ceremony.email || (!ceremony.firstRun && !ceremony.inviteCode)) {
    throw new AuthError(400, "No registration in progress.");
  }
  const verified = await verifyRegistration({
    responseJson: args.responseJson,
    expectedChallenge: ceremony.challenge,
    rpId,
  });
  const email = ceremony.email;
  return db.transaction((tx) => {
    if (ceremony.firstRun) {
      if (hasAnyUser(tx)) throw new AuthError(409, "Setup has already been completed.");
    } else {
      assertEmailFree(tx, email);
    }
    const user = tx
      .insert(users)
      .values({
        id: randomUUID(),
        email,
        name: ceremony.name ?? "",
        password: "",
        isAdmin: ceremony.firstRun ?? false,
        onboardingStep: "COMPLETED",
        createdAt: now,
      })
      .returning()
      .get();
    tx.insert(passkeyCredentials)
      .values({
        id: randomUUID(),
        userId: user.id,
        credentialId: verified.credentialId,
        publicKey: verified.publicKey,
        signCount: verified.signCount,
        deviceName: args.deviceName,
        createdAt: now,
      })
      .run();
    if (ceremony.inviteCode) {
      const { familyId } = acceptInvite(tx, user.id, ceremony.inviteCode, now);
      return { ...user, lastFamilyId: familyId };
    }
    return user;
  });
}

/** Sign-in with a passkey. Without a sign-in name the browser offers the passkeys it has
 *  for this site (discoverable credentials). */
export async function beginPasskeyLogin(
  db: Db,
  args: { email?: string },
  rpId: string,
): Promise<{ options: Awaited<ReturnType<typeof getAuthenticationOptions>>; ceremony: CeremonyState }> {
  let allow: Buffer[] = [];
  if (args.email) {
    const user = db.select().from(users).where(eq(users.email, args.email)).get();
    if (!user) throw new AuthError(400, "No account found with this email.");
    const creds = db
      .select()
      .from(passkeyCredentials)
      .where(eq(passkeyCredentials.userId, user.id))
      .all();
    if (creds.length === 0) throw new AuthError(400, "No passkeys registered for this account.");
    allow = creds.map((c) => c.credentialId as Buffer);
  }
  const options = await getAuthenticationOptions({ rpId, allowCredentialIds: allow });
  return { options, ceremony: { type: "login", challenge: options.challenge, email: args.email } };
}

export async function completePasskeyLogin(
  db: Db,
  args: { responseJson: string },
  ceremony: CeremonyState,
  rpId: string,
  now: Date,
): Promise<User> {
  if (ceremony.type !== "login") throw new AuthError(400, "No login in progress.");
  const parsed = JSON.parse(args.responseJson) as { rawId?: string; id?: string };
  const rawId = parsed.rawId ?? parsed.id;
  if (!rawId) throw new AuthError(400, "Missing credential ID in response.");
  const credentialId = b64urlToBuf(rawId);

  const stored = db
    .select()
    .from(passkeyCredentials)
    .where(eq(passkeyCredentials.credentialId, credentialId))
    .get();
  if (!stored) throw new AuthError(400, "Credential not recognized.");

  const user = db.select().from(users).where(eq(users.id, stored.userId)).get();
  if (!user || (ceremony.email && user.email !== ceremony.email)) {
    throw new AuthError(400, "Credential does not belong to this user.");
  }

  const { newSignCount } = await verifyAuthentication({
    responseJson: args.responseJson,
    expectedChallenge: ceremony.challenge,
    rpId,
    credentialId: stored.credentialId as Buffer,
    publicKey: stored.publicKey as Buffer,
    signCount: stored.signCount,
  });

  db.update(passkeyCredentials)
    .set({ signCount: newSignCount, lastUsedAt: now })
    .where(eq(passkeyCredentials.id, stored.id))
    .run();

  return user;
}
