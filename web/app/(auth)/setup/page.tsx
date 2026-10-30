import { redirect } from "next/navigation";
import { db } from "@/lib/db";
import { hasAnyUser } from "@/lib/auth/first-run";
import { SetupForm } from "./setup-form";

export const dynamic = "force-dynamic";

export default function SetupPage() {
  if (hasAnyUser(db)) redirect("/login");
  return <SetupForm />;
}
