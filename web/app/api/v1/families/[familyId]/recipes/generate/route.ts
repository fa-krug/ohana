import { NextResponse } from "next/server";
import { ZodError } from "zod";
import { db } from "@/lib/db";
import { AuthError } from "@/lib/auth/errors";
import { HttpError } from "@/lib/api/http";
import { defaultAiEnv, familyModel } from "@/lib/assistant/routes";
import { generationStream } from "@/lib/meals/ai/stream";
import { requireFamilyRequest } from "@/lib/meals/route-auth";
import { generateRecipesSchema } from "@/lib/meals/schemas/generate";

export const dynamic = "force-dynamic";

/** Generates recipes with the family's AI (editors): an NDJSON stream (lib/meals/ai/stream.ts).
 *  Nothing is saved; the page saves the recipes the user picks. */
export async function POST(req: Request, { params }: { params: Promise<{ familyId: string }> }) {
  try {
    const { familyId } = await params;
    const user = await requireFamilyRequest(req, familyId, "editor");
    const input = generateRecipesSchema.parse(await req.json().catch(() => ({})));
    const env = defaultAiEnv(db);
    const model = await familyModel(env, familyId);
    if (!model) throw new AuthError(400, "The AI isn't set up yet (Settings → AI)");
    const stream = generationStream({
      db,
      familyId,
      input,
      language: user.preferredLanguage === "de" ? "de" : "en",
      provider: model.provider,
      imageModel: model.imageModel,
      net: env.modelNet,
      signal: req.signal,
    });
    return new Response(stream, {
      headers: { "Content-Type": "application/x-ndjson", "Cache-Control": "no-cache", "X-Accel-Buffering": "no" },
    });
  } catch (e) {
    if (e instanceof AuthError || e instanceof HttpError) return NextResponse.json({ message: e.message }, { status: e.status });
    if (e instanceof ZodError) return NextResponse.json({ message: e.issues[0]?.message ?? "Invalid input." }, { status: 400 });
    throw e;
  }
}
