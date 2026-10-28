import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { isLocale } from "@/lib/i18n/config";

/** Remembers the language in a cookie (also before signing in). */
export async function POST(req: Request) {
  const { lang } = await req.json().catch(() => ({ lang: null }));
  if (!isLocale(lang)) {
    return NextResponse.json({ message: "Unsupported locale" }, { status: 400 });
  }
  (await cookies()).set("lang", lang, {
    path: "/",
    maxAge: 60 * 60 * 24 * 365,
    sameSite: "lax",
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
  });
  return NextResponse.json({ ok: true });
}
