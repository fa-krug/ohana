// The account routes of the native app (apple/), under /api/v1/me/... (GET and DELETE
// /api/v1/me themselves are app/api/v1/me/route.ts). They do what the web's account page does
// with server actions (app/actions/account.ts, auth.ts), with the same lib functions and rules;
// the "session" of the password rules is the device's API token (never `canReset`), so setting
// or removing the password signs out every browser session. Password checks count as failed
// sign-ins of the account (rate-limit.ts), so a stolen token can't guess the password.
//
// GET    /me/account                         user, passkeys, API tokens, open browser sessions
// PATCH  /me/profile {name?, preferredLanguage?}            → user
// PUT    /me/email {newEmail, currentPassword}               → user
// PUT    /me/password {currentPassword?, newPassword}        → user (sets or changes it)
// DELETE /me/password {currentPassword}                      → user (needs a passkey)
// GET    /me/passkeys
// PATCH  /me/passkeys/{id} {deviceName}
// DELETE /me/passkeys/{id}                   (not the last way to sign in)
// GET    /me/tokens                          API tokens; `current` is the request's own
// POST   /me/tokens {name}                   → {token (shown once), item}
// DELETE /me/tokens/{id}                     (the request's own token too: that signs it out)
// GET    /me/sessions                        → {count} of signed-in browsers
// DELETE /me/sessions                        signs out every browser ("other devices")
// /me/push[/test]                            push to this device (lib/push/app-routes.ts)

import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { users } from "@/lib/db/schema";
import { type AppCtx, type AppRoutes, runAppRoutes } from "@/lib/api/app-router";
import { pushRoutes } from "@/lib/push/app-routes";
import type { RelayClient } from "@/lib/push/relay";
import { HttpError } from "@/lib/api/http";
import { apiTokenSchema, emailChangeSchema, profileSchema, removePasswordSchema, setPasswordSchema } from "@/lib/schemas/auth";
import { changeEmail } from "./email";
import { AuthError } from "./errors";
import { deletePasskey, listPasskeys, renamePasskey } from "./passkey-management";
import { hasUsablePassword, verifyPassword } from "./password";
import { removePassword, setPassword } from "./password-management";
import { updateProfile } from "./profile";
import { assertNotLimited, recordFailure } from "./rate-limit";
import { serializeUser } from "./serialize";
import { type AuthToken, type User, createToken, deleteOwnToken, deleteUserTokens, listTokens } from "./tokens";

export interface AppTokenDto {
  id: string;
  name: string;
  createdAt: Date;
  lastUsedAt: Date | null;
  /** The token of the request: this device's. */
  current: boolean;
}

const WRONG_PASSWORD = "Current password is incorrect.";

function tokenDto(row: AuthToken, currentId: string): AppTokenDto {
  return { id: row.id, name: row.name, createdAt: row.createdAt, lastUsedAt: row.lastUsedAt, current: row.id === currentId };
}

function tokensOf(c: AppCtx): AppTokenDto[] {
  return listTokens(c.db, c.user.id, "api").map((t) => tokenDto(t, c.token.id));
}

function sessionCount(db: Db, userId: string, now: Date): number {
  return listTokens(db, userId, "session").filter((t) => !t.expiresAt || t.expiresAt > now).length;
}

function freshUser(db: Db, userId: string): User {
  const user = db.select().from(users).where(eq(users.id, userId)).get();
  if (!user) throw new AuthError(404, "User not found.");
  return user;
}

/** Runs a check of the current password, counting a wrong one as a failed sign-in. */
async function withPasswordCheck<T>(c: AppCtx, fn: () => Promise<T>): Promise<T> {
  const key = `login:${c.user.email}`;
  assertNotLimited(c.db, key, c.now);
  try {
    return await fn();
  } catch (e) {
    if (e instanceof AuthError && e.message === WRONG_PASSWORD) recordFailure(c.db, key, c.now);
    throw e;
  }
}

/** The request's token as the password rules' session: it is kept, browsers are signed out. */
function asSession(c: AppCtx) {
  return { id: c.token.id, canReset: false };
}

const account = (c: AppCtx) => ({
  user: serializeUser(c.db, freshUser(c.db, c.user.id)),
  passkeys: listPasskeys(c.db, c.user.id),
  tokens: tokensOf(c),
  sessions: sessionCount(c.db, c.user.id, c.now),
});

const routes: AppRoutes = [
  [["account"], { GET: account }],
  [
    ["profile"],
    {
      PATCH: async (c) =>
        serializeUser(c.db, updateProfile(c.db, c.user.id, profileSchema.parse(await c.body()))),
    },
  ],
  [
    ["email"],
    {
      PUT: async (c) => {
        const body = await c.body();
        const { newEmail } = emailChangeSchema.parse({ newEmail: body.newEmail });
        if (!hasUsablePassword(c.user.password)) {
          throw new AuthError(400, "Set a password or confirm with a passkey.");
        }
        const currentPassword = typeof body.currentPassword === "string" ? body.currentPassword : "";
        await withPasswordCheck(c, async () => {
          if (!currentPassword || !(await verifyPassword(c.user.password, currentPassword))) {
            throw new AuthError(400, WRONG_PASSWORD);
          }
        });
        return serializeUser(c.db, changeEmail(c.db, c.user.id, newEmail));
      },
    },
  ],
  [
    ["password"],
    {
      PUT: async (c) => {
        const input = setPasswordSchema.parse(await c.body());
        await withPasswordCheck(c, () => setPassword(c.db, c.user.id, input, asSession(c)));
        return serializeUser(c.db, freshUser(c.db, c.user.id));
      },
      DELETE: async (c) => {
        const input = removePasswordSchema.parse(await c.body());
        await withPasswordCheck(c, () => removePassword(c.db, c.user.id, input, asSession(c)));
        return serializeUser(c.db, freshUser(c.db, c.user.id));
      },
    },
  ],
  [["passkeys"], { GET: (c) => ({ passkeys: listPasskeys(c.db, c.user.id) }) }],
  [
    ["passkeys", "*"],
    {
      PATCH: async (c, [id]) => {
        const name = (await c.body()).deviceName;
        if (typeof name !== "string") throw new HttpError(400, "deviceName is required");
        renamePasskey(c.db, c.user.id, id, name);
        return { passkeys: listPasskeys(c.db, c.user.id) };
      },
      DELETE: (c, [id]) => {
        deletePasskey(c.db, c.user.id, id);
        return { passkeys: listPasskeys(c.db, c.user.id) };
      },
    },
  ],
  [
    ["tokens"],
    {
      GET: (c) => ({ tokens: tokensOf(c) }),
      POST: async (c) => {
        const { name } = apiTokenSchema.parse(await c.body());
        const { token, row } = createToken(c.db, { userId: c.user.id, kind: "api", name }, c.now);
        return { token, item: tokenDto(row, c.token.id) };
      },
    },
  ],
  [
    ["tokens", "*"],
    {
      DELETE: (c, [id]) => {
        if (!deleteOwnToken(c.db, c.user.id, id, "api")) throw new AuthError(404, "Token not found.");
        return { ok: true, signedOut: id === c.token.id };
      },
    },
  ],
  [
    ["sessions"],
    {
      GET: (c) => ({ count: sessionCount(c.db, c.user.id, c.now) }),
      DELETE: (c) => {
        // Every browser: the app's own sign-in is its API token, not a session.
        const count = sessionCount(c.db, c.user.id, c.now);
        deleteUserTokens(c.db, c.user.id, "session");
        return { ok: true, count };
      },
    },
  ],
];

/** /api/v1/me/{path…} for the app. `relay` replaces the push relay client (tests). */
export function handleAccountApp(
  db: Db,
  req: Request,
  path: string[],
  now?: Date,
  opts: { relay?: RelayClient } = {},
): Promise<Response> {
  return runAppRoutes([...routes, ...pushRoutes(opts)], db, req, path, { now });
}
