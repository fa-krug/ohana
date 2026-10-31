import { randomUUID } from "node:crypto";
import { desc, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { passkeyCredentials, users } from "@/lib/db/schema";
import type { CeremonyState } from "./ceremony";
import { AuthError } from "./errors";
import { afterPasskey } from "./onboarding";
import { hasUsablePassword } from "./password";
import { getRegistrationOptions, verifyRegistration } from "./webauthn";

export interface PasskeyDto {
  id: string;
  deviceName: string;
  createdAt: Date;
  lastUsedAt: Date | null;
}

function requireUser(db: Db, userId: string) {
  const user = db.select().from(users).where(eq(users.id, userId)).get();
  if (!user) throw new AuthError(404, "User not found.");
  return user;
}

export function listPasskeys(db: Db, userId: string): PasskeyDto[] {
  return db
    .select({
      id: passkeyCredentials.id,
      deviceName: passkeyCredentials.deviceName,
      createdAt: passkeyCredentials.createdAt,
      lastUsedAt: passkeyCredentials.lastUsedAt,
    })
    .from(passkeyCredentials)
    .where(eq(passkeyCredentials.userId, userId))
    .orderBy(desc(passkeyCredentials.createdAt))
    .all();
}

export async function beginAddPasskey(
  db: Db,
  userId: string,
  rpId: string,
): Promise<{ options: Awaited<ReturnType<typeof getRegistrationOptions>>; ceremony: CeremonyState }> {
  const user = requireUser(db, userId);
  const existing = db
    .select()
    .from(passkeyCredentials)
    .where(eq(passkeyCredentials.userId, userId))
    .all();
  const options = await getRegistrationOptions({
    userId: user.id,
    userEmail: user.email,
    rpId,
    excludeCredentialIds: existing.map((c) => c.credentialId as Buffer),
  });
  return { options, ceremony: { type: "add", challenge: options.challenge } };
}

export async function completeAddPasskey(
  db: Db,
  args: { userId: string; responseJson: string; deviceName: string },
  ceremony: CeremonyState,
  rpId: string,
  now: Date,
): Promise<PasskeyDto> {
  if (ceremony.type !== "add") throw new AuthError(400, "No pending passkey addition.");
  const user = requireUser(db, args.userId);
  const verified = await verifyRegistration({
    responseJson: args.responseJson,
    expectedChallenge: ceremony.challenge,
    rpId,
  });
  const cred = db
    .insert(passkeyCredentials)
    .values({
      id: randomUUID(),
      userId: user.id,
      credentialId: verified.credentialId,
      publicKey: verified.publicKey,
      signCount: verified.signCount,
      deviceName: args.deviceName,
      createdAt: now,
    })
    .returning()
    .get();
  afterPasskey(db, user);
  return { id: cred.id, deviceName: cred.deviceName, createdAt: cred.createdAt, lastUsedAt: null };
}

export function renamePasskey(db: Db, userId: string, passkeyId: string, deviceName: string): void {
  const name = deviceName.trim().slice(0, 100);
  const res = db
    .update(passkeyCredentials)
    .set({ deviceName: name })
    .where(eq(passkeyCredentials.id, passkeyId))
    .returning({ userId: passkeyCredentials.userId })
    .get();
  if (!res || res.userId !== userId) throw new AuthError(404, "Passkey not found.");
}

export function deletePasskey(db: Db, userId: string, passkeyId: string): void {
  const user = requireUser(db, userId);
  const cred = db
    .select()
    .from(passkeyCredentials)
    .where(eq(passkeyCredentials.id, passkeyId))
    .get();
  if (!cred || cred.userId !== userId) throw new AuthError(404, "Passkey not found.");

  const count = db
    .select()
    .from(passkeyCredentials)
    .where(eq(passkeyCredentials.userId, userId))
    .all().length;
  if (count <= 1 && !hasUsablePassword(user.password)) {
    throw new AuthError(400, "Cannot delete your only passkey without a password set.");
  }
  db.delete(passkeyCredentials).where(eq(passkeyCredentials.id, passkeyId)).run();
}
