import { db } from "@/lib/db";
import { pathOf } from "@/lib/api/app-router";
import { handleAccountApp } from "@/lib/auth/app-routes";

export const dynamic = "force-dynamic";

// The app's account routes (lib/auth/app-routes.ts): /api/v1/me/...
async function handler(req: Request, { params }: { params: Promise<{ path: string[] }> }) {
  return handleAccountApp(db, req, await pathOf(params));
}

export const GET = handler;
export const POST = handler;
export const PATCH = handler;
export const PUT = handler;
export const DELETE = handler;
