"use server";

import { revalidatePath } from "next/cache";
import { AuthError } from "@/lib/auth/errors";
import { changeEmail } from "@/lib/auth/email";
import { deletePasskey, renamePasskey } from "@/lib/auth/passkey-management";
import { hasUsablePassword, verifyPassword } from "@/lib/auth/password";
import { updateProfile } from "@/lib/auth/profile";
import { createToken, deleteOwnToken, deleteUserTokens } from "@/lib/auth/tokens";
import { run } from "@/lib/actions/result";
import { apiTokenSchema, emailChangeSchema, profileSchema } from "@/lib/schemas/auth";

export const updateProfileAction = async (input: unknown) =>
  run(({ db, user }) => {
    updateProfile(db, user.id, profileSchema.parse(input));
    revalidatePath("/", "layout");
  });

export const changeEmailAction = async (input: { newEmail: string; currentPassword?: string }) =>
  run(async ({ db, user }) => {
    const { newEmail } = emailChangeSchema.parse({ newEmail: input.newEmail });
    if (!hasUsablePassword(user.password)) {
      throw new AuthError(400, "Set a password or confirm with a passkey.");
    }
    if (!input.currentPassword || !(await verifyPassword(user.password, input.currentPassword))) {
      throw new AuthError(400, "Current password is incorrect.");
    }
    changeEmail(db, user.id, newEmail);
  });

export const renamePasskeyAction = async (passkeyId: string, deviceName: string) =>
  run(({ db, user }) => renamePasskey(db, user.id, passkeyId, deviceName));

export const deletePasskeyAction = async (passkeyId: string) =>
  run(({ db, user }) => deletePasskey(db, user.id, passkeyId));

export const createApiTokenAction = async (input: unknown) =>
  run(({ db, user, now }) => {
    const { name } = apiTokenSchema.parse(input);
    return { token: createToken(db, { userId: user.id, kind: "api", name }, now).token };
  });

export const deleteApiTokenAction = async (tokenId: string) =>
  run(({ db, user }) => {
    if (!deleteOwnToken(db, user.id, tokenId, "api")) throw new AuthError(404, "Token not found.");
  });

export const signOutOthersAction = async () =>
  run(({ db, user, token }) => deleteUserTokens(db, user.id, "session", token.id));
