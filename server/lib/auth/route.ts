import { ZodError } from "zod";
import { AuthError } from "./errors";

/** Runs a route handler body, answering AuthError / ZodError as JSON `{ message }`. */
export async function handle(fn: () => Promise<unknown>): Promise<Response> {
  try {
    return Response.json(await fn());
  } catch (e) {
    if (e instanceof AuthError) return Response.json({ message: e.message }, { status: e.status });
    if (e instanceof ZodError) {
      return Response.json({ message: e.issues[0]?.message ?? "Invalid input." }, { status: 400 });
    }
    throw e;
  }
}
