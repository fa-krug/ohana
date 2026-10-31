// /api/auth/...: what the sign-in pages (http/pages) call from the browser. The WebAuthn
// ceremonies keep their state in a signed cookie; everything else signs in with the session
// cookie. Every route here is for this site's own pages only (assertSameOrigin).

import { Hono } from "hono";
import { z } from "zod";
import type { Db } from "@/lib/db";
import { readCeremonyCookie, clearCeremonyCookie, setCeremonyCookie } from "@/lib/auth/ceremony-cookie";
import { pairDevice } from "@/lib/auth/device-pairing";
import { changeEmail } from "@/lib/auth/email";
import { AuthError } from "@/lib/auth/errors";
import { registerFirstUser } from "@/lib/auth/first-run";
import { loginWithPassword } from "@/lib/auth/login";
import { assertSameOrigin } from "@/lib/auth/origin";
import { beginPasskeyLogin, beginPasskeyRegistration, completePasskeyLogin, completePasskeyRegistration } from "@/lib/auth/passkey-auth";
import { beginAddPasskey, completeAddPasskey } from "@/lib/auth/passkey-management";
import { hasUsablePassword, verifyPassword } from "@/lib/auth/password";
import { setPassword, skipPasskey } from "@/lib/auth/password-management";
import { updateProfile } from "@/lib/auth/profile";
import { beginReauth, completeReauth } from "@/lib/auth/reauth";
import { registerWithPassword } from "@/lib/auth/register";
import { handle } from "@/lib/auth/route";
import { serializeUser } from "@/lib/auth/serialize";
import { type Auth, clearSessionCookie, currentRpId, getAuth, requireSessionUser, setSessionCookie } from "@/lib/auth/session";
import { redeemSetupLink } from "@/lib/auth/setup-link";
import { acceptInvite } from "@/lib/families/invites";
import { cookieSecure } from "@/lib/auth/config";
import { isLocale } from "@/lib/i18n/config";
import { cookies } from "@/lib/http/request-context";
import {
  emailChangeSchema,
  loginPasswordSchema,
  passkeyCompleteSchema,
  passkeyLoginBeginSchema,
  passkeyRegisterBeginSchema,
  registerFirstUserSchema,
  registerPasswordSchema,
  setPasswordSchema,
} from "@/lib/schemas/auth";

async function body(req: Request): Promise<unknown> {
  return req.json().catch(() => ({}));
}

async function requireSession(): Promise<Auth> {
  const auth = await getAuth();
  if (!auth) throw new AuthError(401, "Not signed in.");
  return auth;
}

/** Runs a ceremony's second step: the ceremony cookie is read first and always cleared. */
async function withCeremony(fn: (ceremony: Awaited<ReturnType<typeof readCeremonyCookie>>) => Promise<unknown>): Promise<Response> {
  const ceremony = await readCeremonyCookie();
  try {
    return await handle(() => fn(ceremony));
  } finally {
    await clearCeremonyCookie();
  }
}

export function authRoutes(db: Db): Hono {
  const auth = new Hono();
  // Everything here is called by this site's pages only.
  auth.use("*", async (c, next) => {
    try {
      assertSameOrigin(c.req.raw);
    } catch (e) {
      if (e instanceof AuthError) return c.json({ message: e.message }, e.status as 403);
      throw e;
    }
    await next();
  });

  // ---- passwords and accounts ----
  auth.post("/login", (c) =>
    handle(async () => {
      const user = await loginWithPassword(db, loginPasswordSchema.parse(await body(c.req.raw)), new Date());
      await setSessionCookie(user.id);
      return serializeUser(db, user);
    }),
  );
  // A new account with an invite code.
  auth.post("/register", (c) =>
    handle(async () => {
      const user = await registerWithPassword(db, registerPasswordSchema.parse(await body(c.req.raw)), new Date());
      await setSessionCookie(user.id);
      return serializeUser(db, user);
    }),
  );
  // The first account of a fresh server (an administrator).
  auth.post("/setup", (c) =>
    handle(async () => {
      const user = await registerFirstUser(db, registerFirstUserSchema.parse(await body(c.req.raw)), new Date());
      await setSessionCookie(user.id);
      return serializeUser(db, user);
    }),
  );
  // Uses up a setup link and signs its user in, allowed to set a new password.
  auth.post("/setup-link", (c) =>
    handle(async () => {
      const { token } = z.object({ token: z.string().min(1) }).parse(await body(c.req.raw));
      const user = redeemSetupLink(db, token, new Date());
      await setSessionCookie(user.id, { canReset: true });
      return serializeUser(db, user);
    }),
  );
  auth.post("/logout", () =>
    handle(async () => {
      await clearSessionCookie();
      return { ok: true };
    }),
  );
  // Sets or changes the password (the current one unless the session came from a setup link).
  auth.post("/password", (c) =>
    handle(async () => {
      const { user, token } = await requireSession();
      await setPassword(db, user.id, setPasswordSchema.parse(await body(c.req.raw)), token);
      return { ok: true };
    }),
  );
  auth.post("/skip-passkey", () =>
    handle(async () => {
      const { user } = await requireSession();
      skipPasskey(db, user.id);
      return { ok: true };
    }),
  );
  // Changes the email, confirmed with the current password (passkey-only accounts: /webauthn/reauth).
  auth.post("/email", (c) =>
    handle(async () => {
      const { user } = await requireSession();
      const input = z.object({ newEmail: z.string(), currentPassword: z.string().optional() }).parse(await body(c.req.raw));
      const { newEmail } = emailChangeSchema.parse({ newEmail: input.newEmail });
      if (!hasUsablePassword(user.password)) throw new AuthError(400, "Set a password or confirm with a passkey.");
      if (!input.currentPassword || !(await verifyPassword(user.password, input.currentPassword))) {
        throw new AuthError(400, "Current password is incorrect.");
      }
      return serializeUser(db, changeEmail(db, user.id, newEmail));
    }),
  );
  // The language of the pages: a cookie, and the account's language when signed in.
  auth.post("/language", (c) =>
    handle(async () => {
      const { lang } = z.object({ lang: z.string() }).parse(await body(c.req.raw));
      if (!isLocale(lang)) throw new AuthError(400, "Unsupported language.");
      cookies().set("lang", lang, { path: "/", maxAge: 60 * 60 * 24 * 365, sameSite: "lax", httpOnly: true, secure: cookieSecure() });
      const session = await getAuth();
      if (session) updateProfile(db, session.user.id, { preferredLanguage: lang });
      return { ok: true };
    }),
  );

  // ---- the native app ----
  // Gives the app an API token (lib/auth/device-pairing.ts): `{ callbackUrl }` to go to.
  auth.post("/pair", (c) =>
    handle(async () => {
      const { user } = await requireSession();
      if (user.onboardingStep !== "COMPLETED") throw new AuthError(403, "Finish setting up your account first.");
      const args = z.object({ state: z.string(), deviceName: z.string().default("") }).parse(await body(c.req.raw));
      return pairDevice(db, user.id, args, new Date());
    }),
  );
  // Joins a family with an invite, signed in.
  auth.post("/invites/accept", (c) =>
    handle(async () => {
      const { user } = await requireSession();
      const { code } = z.object({ code: z.string().min(1) }).parse(await body(c.req.raw));
      return acceptInvite(db, user.id, code, new Date());
    }),
  );

  // ---- WebAuthn ----
  // Signing in with a passkey.
  auth.post("/webauthn/login/begin", (c) =>
    handle(async () => {
      const args = passkeyLoginBeginSchema.parse(await body(c.req.raw));
      const { options, ceremony } = await beginPasskeyLogin(db, args, await currentRpId());
      await setCeremonyCookie(ceremony);
      return options;
    }),
  );
  auth.post("/webauthn/login/complete", (c) =>
    withCeremony(async (ceremony) => {
      const { credential } = passkeyCompleteSchema.parse(await body(c.req.raw));
      if (!ceremony) throw new AuthError(400, "No login in progress.");
      const user = await completePasskeyLogin(db, { responseJson: credential }, ceremony, await currentRpId(), new Date());
      await setSessionCookie(user.id);
      return serializeUser(db, user);
    }),
  );
  // A new account with a passkey: with an invite code, or the first account.
  auth.post("/webauthn/register/begin", (c) =>
    handle(async () => {
      const args = passkeyRegisterBeginSchema.parse(await body(c.req.raw));
      const { options, ceremony } = await beginPasskeyRegistration(db, args, await currentRpId(), new Date());
      await setCeremonyCookie(ceremony);
      return options;
    }),
  );
  auth.post("/webauthn/register/complete", (c) =>
    withCeremony(async (ceremony) => {
      const { credential, deviceName } = passkeyCompleteSchema.parse(await body(c.req.raw));
      if (!ceremony) throw new AuthError(400, "No registration in progress.");
      const user = await completePasskeyRegistration(db, { responseJson: credential, deviceName }, ceremony, await currentRpId(), new Date());
      await setSessionCookie(user.id);
      return serializeUser(db, user);
    }),
  );
  // Adding a passkey to the signed-in account (onboarding, the account page).
  auth.post("/webauthn/add/begin", () =>
    handle(async () => {
      const user = await requireSessionUser();
      const { options, ceremony } = await beginAddPasskey(db, user.id, await currentRpId());
      await setCeremonyCookie(ceremony);
      return options;
    }),
  );
  auth.post("/webauthn/add/complete", (c) =>
    withCeremony(async (ceremony) => {
      const user = await requireSessionUser();
      const { credential, deviceName } = passkeyCompleteSchema.parse(await body(c.req.raw));
      if (!ceremony) throw new AuthError(400, "No pending passkey addition.");
      return completeAddPasskey(db, { userId: user.id, responseJson: credential, deviceName }, ceremony, await currentRpId(), new Date());
    }),
  );
  // Confirming the account with a passkey, then changing its email.
  auth.post("/webauthn/reauth/begin", () =>
    handle(async () => {
      const user = await requireSessionUser();
      const { options, ceremony } = await beginReauth(db, user.id, await currentRpId());
      await setCeremonyCookie(ceremony);
      return options;
    }),
  );
  auth.post("/webauthn/reauth/complete", (c) =>
    withCeremony(async (ceremony) => {
      const user = await requireSessionUser();
      const { credential, newEmail } = z
        .object({ credential: z.string().min(1), newEmail: z.string().trim().toLowerCase().email() })
        .parse(await body(c.req.raw));
      if (!ceremony) throw new AuthError(400, "No re-authentication in progress.");
      await completeReauth(db, { userId: user.id, responseJson: credential }, ceremony, await currentRpId());
      return serializeUser(db, changeEmail(db, user.id, newEmail));
    }),
  );

  return auth;
}
