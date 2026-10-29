// The assistant's tool registry: every module's tools in one list. A module adds its own file
// (e.g. meals.ts) exporting `Record<string, Tool>` and spreads it into TOOLS.

import { HttpError, objectOf } from "@/lib/api/http";
import type { ToolSpec } from "../provider";
import { calendarTools } from "./calendar";
import { NeedsConfirmation, type Tool, type ToolContext, type ToolResult } from "./common";
import { financeTools } from "./finance";
import { generalTools } from "./general";
import { webTools } from "./web";

export * from "./common";

export const TOOLS: Record<string, Tool> = {
  ...calendarTools,
  ...financeTools,
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
    const message = err instanceof HttpError || err instanceof NeedsConfirmation
      ? err.message
      : "The tool failed";
    if (!(err instanceof HttpError || err instanceof NeedsConfirmation)) console.error(err);
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
