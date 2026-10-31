import { ZodError } from "zod";
import { db, type Db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { type Auth, getAuth } from "@/lib/auth/session";

export type Result<T = undefined> =
  | { ok: true; data: T }
  | { ok: false; status: number; message: string };

export function fail(e: unknown): Result<never> {
  if (e instanceof AuthError) return { ok: false, status: e.status, message: e.message };
  if (e instanceof ZodError) {
    return { ok: false, status: 400, message: e.issues[0]?.message ?? "Invalid input." };
  }
  throw e;
}

type Ctx = Auth & { db: Db; now: Date };

/** Runs `fn` for the signed-in user (an admin with `admin`), translating errors. */
export async function run<T>(
  fn: (ctx: Ctx) => Promise<T> | T,
  opts: { admin?: boolean } = {},
): Promise<Result<T>> {
  try {
    const auth = await getAuth();
    if (!auth) throw new AuthError(401, "Not signed in.");
    if (opts.admin && !auth.user.isAdmin) throw new AuthError(403, "Administrators only.");
    return { ok: true, data: await fn({ ...auth, db, now: new Date() }) };
  } catch (e) {
    return fail(e);
  }
}
