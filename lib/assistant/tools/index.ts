// The assistant's tool registry: every module's tools in one list. A module adds its own file
// (e.g. meals.ts) exporting `Record<string, Tool>` and spreads it into TOOLS.

import { ZodError } from "zod";
import { HttpError, objectOf } from "@/lib/api/http";
import { AuthError } from "@/lib/auth/errors";
import type { ToolSpec } from "../provider";
import { calendarTools } from "./calendar";
import { NeedsConfirmation, type Tool, type ToolContext, type ToolResult } from "./common";
import { financeTools } from "./finance";
import { appointmentTools } from "./appointments";
import { eventTools } from "./events";
import { generalTools } from "./general";
import { mealTools } from "./meals";
import { webTools } from "./web";

export * from "./common";

export const TOOLS: Record<string, Tool> = {
  ...calendarTools,
  ...eventTools,
  ...financeTools,
  ...mealTools,
  ...appointmentTools,
  ...generalTools,
  ...webTools,
};

/** The tools for a chat: without writes if they're off, without search if it isn't set up. */
export function toolsFor(opts: { writes: boolean; search: boolean }): ToolSpec[] {
  return Object.values(TOOLS)
    .filter((t) => (opts.writes || !t.write) && (opts.search || !t.needsSearch))
    .map((t) => ({ type: "function", function: t.spec }));
}

/** A tool that only reads, so calls of it can run side by side (unknown ones fail right away). */
export function readsOnly(name: string): boolean {
  return !TOOLS[name]?.write && name !== "ask_user";
}

/** Runs a tool call; errors come back to the model as {"error": "..."} so it can react. */
export async function runTool(
  name: string,
  rawArgs: string,
  ctx: ToolContext,
  allowed: Set<string>,
): Promise<ToolResult & { ok: boolean }> {
  const tool = TOOLS[name];
  if (!tool || !allowed.has(name)) {
    return { ok: false, result: { error: `Unknown tool "${name}"` }, summary: name };
  }
  let args: Record<string, unknown>;
  try {
    args = rawArgs.trim() ? objectOf(JSON.parse(rawArgs), "arguments") : {};
  } catch {
    return { ok: false, result: { error: "The arguments must be a JSON object" }, summary: name };
  }
  try {
    return { ok: true, ...(await tool.run(args, ctx)) };
  } catch (err) {
    // The modules' own errors (AuthError of lib/meals and lib/appointments, zod's) are the
    // model's to read too.
    const known = err instanceof HttpError || err instanceof NeedsConfirmation || err instanceof AuthError;
    const message = known
      ? (err as Error).message
      : err instanceof ZodError
        ? `${err.issues[0]?.path.join(".") || "input"}: ${err.issues[0]?.message ?? "invalid"}`
        : "The tool failed";
    if (!known && !(err instanceof ZodError)) console.error(err);
    return {
      ok: false,
      result: {
        error: message,
        ...(err instanceof NeedsConfirmation ? { needsConfirmation: true } : {}),
      },
      summary: message,
    };
  }
}
