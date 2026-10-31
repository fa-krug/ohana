"use server";

import { db } from "@/lib/db";
import { registerFirstUser } from "@/lib/auth/first-run";
import { loginWithPassword } from "@/lib/auth/login";
import { removePassword, setPassword, skipPasskey } from "@/lib/auth/password-management";
import { registerWithPassword } from "@/lib/auth/register";
import { serializeUser, type UserDto } from "@/lib/auth/serialize";
import { clearSessionCookie, setSessionCookie } from "@/lib/auth/session";
import { redeemSetupLink } from "@/lib/auth/setup-link";
import { fail, run, type Result } from "@/lib/actions/result";
import {
  loginPasswordSchema,
  registerFirstUserSchema,
  registerPasswordSchema,
  removePasswordSchema,
  setPasswordSchema,
} from "@/lib/schemas/auth";

export async function loginPasswordAction(input: unknown): Promise<Result<UserDto>> {
  try {
    const user = await loginWithPassword(db, loginPasswordSchema.parse(input), new Date());
    await setSessionCookie(user.id);
    return { ok: true, data: serializeUser(db, user) };
  } catch (e) {
    return fail(e);
  }
}

export async function registerPasswordAction(input: unknown): Promise<Result<UserDto>> {
  try {
    const user = await registerWithPassword(db, registerPasswordSchema.parse(input), new Date());
    await setSessionCookie(user.id);
    return { ok: true, data: serializeUser(db, user) };
  } catch (e) {
    return fail(e);
  }
}

export async function registerFirstUserPasswordAction(input: unknown): Promise<Result<UserDto>> {
  try {
    const user = await registerFirstUser(db, registerFirstUserSchema.parse(input), new Date());
    await setSessionCookie(user.id);
    return { ok: true, data: serializeUser(db, user) };
  } catch (e) {
    return fail(e);
  }
}

/** Uses up a setup link and signs its user in, allowed to set a new password. */
export async function redeemSetupLinkAction(token: string): Promise<Result<UserDto>> {
  try {
    const user = redeemSetupLink(db, token, new Date());
    await setSessionCookie(user.id, { canReset: true });
    return { ok: true, data: serializeUser(db, user) };
  } catch (e) {
    return fail(e);
  }
}

export async function logoutAction(): Promise<Result> {
  await clearSessionCookie();
  return { ok: true, data: undefined };
}

export const setPasswordAction = async (input: unknown) =>
  run(({ db, user, token }) => setPassword(db, user.id, setPasswordSchema.parse(input), token));

export const removePasswordAction = async (input: unknown) =>
  run(({ db, user, token }) => removePassword(db, user.id, removePasswordSchema.parse(input), token));

export const skipPasskeyAction = async () => run(({ db, user }) => skipPasskey(db, user.id));
