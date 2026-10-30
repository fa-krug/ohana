import { redirect } from "next/navigation";
import { db } from "@/lib/db";
import { hasAnyUser } from "@/lib/auth/first-run";
import { safeNext } from "@/lib/auth/device-pairing";
import { SetupForm } from "./setup-form";

export const dynamic = "force-dynamic";

export default async function SetupPage({ searchParams }: { searchParams: Promise<{ next?: string }> }) {
  // `next`: where to go once the first account is set up (the native app's pairing page).
  const next = safeNext((await searchParams).next);
  if (hasAnyUser(db)) redirect(next ? `/login?${new URLSearchParams({ next })}` : "/login");
  return <SetupForm next={next} />;
}
