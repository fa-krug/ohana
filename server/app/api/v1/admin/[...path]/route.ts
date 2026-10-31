import { db } from "@/lib/db";
import { pathOf } from "@/lib/api/app-router";
import { handleAdminApp } from "@/lib/admin/app-routes";

export const dynamic = "force-dynamic";

// The app's administration routes (lib/admin/app-routes.ts): /api/v1/admin/...
async function handler(req: Request, { params }: { params: Promise<{ path: string[] }> }) {
  return handleAdminApp(db, req, await pathOf(params));
}

export const GET = handler;
export const POST = handler;
export const PATCH = handler;
export const PUT = handler;
export const DELETE = handler;
