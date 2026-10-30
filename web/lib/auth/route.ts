import { NextResponse } from "next/server";
import { ZodError } from "zod";
import { AuthError } from "./errors";

/** Runs a route handler body, answering AuthError / ZodError as JSON `{ message }`. */
export async function handle(fn: () => Promise<unknown>): Promise<NextResponse> {
  try {
    return NextResponse.json(await fn());
  } catch (e) {
    if (e instanceof AuthError) return NextResponse.json({ message: e.message }, { status: e.status });
    if (e instanceof ZodError) {
      return NextResponse.json({ message: e.issues[0]?.message ?? "Invalid input." }, { status: 400 });
    }
    throw e;
  }
}
