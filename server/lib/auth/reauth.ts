import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { passkeyCredentials, users } from "@/lib/db/schema";
import type { CeremonyState } from "./ceremony";
import { AuthError } from "./errors";
import { b64urlToBuf, getAuthenticationOptions, verifyAuthentication } from "./webauthn";

export async function beginReauth(
  db: Db,
  userId: string,
  rpId: string,
): Promise<{ options: Awaited<ReturnType<typeof getAuthenticationOptions>>; ceremony: CeremonyState }> {
  const user = db.select().from(users).where(eq(users.id, userId)).get();
  if (!user) throw new AuthError(404, "User not found.");
  const creds = db
    .select()
    .from(passkeyCredentials)
    .where(eq(passkeyCredentials.userId, userId))
    .all();
  if (creds.length === 0) throw new AuthError(400, "No passkeys registered for this account.");

  const options = await getAuthenticationOptions({
    rpId,
    allowCredentialIds: creds.map((c) => c.credentialId as Buffer),
  });
  return { options, ceremony: { type: "reauth", challenge: options.challenge } };
}

export async function completeReauth(
  db: Db,
  args: { userId: string; responseJson: string },
  ceremony: CeremonyState,
  rpId: string,
): Promise<void> {
  if (ceremony.type !== "reauth") throw new AuthError(400, "No re-authentication in progress.");
  const parsed = JSON.parse(args.responseJson) as { rawId?: string; id?: string };
  const rawId = parsed.rawId ?? parsed.id;
  if (!rawId) throw new AuthError(400, "Missing credential ID in response.");
  const credentialId = b64urlToBuf(rawId);

  const stored = db
    .select()
    .from(passkeyCredentials)
    .where(eq(passkeyCredentials.credentialId, credentialId))
    .get();
  if (!stored || stored.userId !== args.userId) {
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
    .set({ signCount: newSignCount })
    .where(eq(passkeyCredentials.id, stored.id))
    .run();
}
