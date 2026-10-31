import { redirect } from "next/navigation";
import { db } from "@/lib/db";
import { hasAnyUser } from "@/lib/auth/first-run";
import { homeFor } from "@/lib/auth/redirect";
import { safeNext } from "@/lib/auth/device-pairing";
import { getSession } from "@/lib/auth/session";
import { LoginForm } from "./login-form";

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string }> }) {
  // `next`: where to go once signed in (the native app's pairing page uses it).
  const next = safeNext((await searchParams).next);
  const user = await getSession();
  if (user) redirect(homeFor(user, next));
  // A fresh install: the first account, then on to `next` (e.g. the app's pairing).
  if (!hasAnyUser(db)) redirect(next ? `/setup?${new URLSearchParams({ next })}` : "/setup");
  return <LoginForm next={next} />;
}
