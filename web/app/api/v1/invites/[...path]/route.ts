import { db } from "@/lib/db";
import { pathOf } from "@/lib/api/app-router";
import { handleInvitesApp } from "@/lib/families/invite-routes";

export const dynamic = "force-dynamic";

// Joining a family with an invite from the app (lib/families/invite-routes.ts): /api/v1/invites/...
async function handler(req: Request, { params }: { params: Promise<{ path: string[] }> }) {
  return handleInvitesApp(db, req, await pathOf(params));
}

export const GET = handler;
export const POST = handler;
export const PATCH = handler;
export const PUT = handler;
export const DELETE = handler;
