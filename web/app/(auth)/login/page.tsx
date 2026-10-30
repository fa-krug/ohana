import { redirect } from "next/navigation";
import { db } from "@/lib/db";
import { hasAnyUser } from "@/lib/auth/first-run";
import { homeFor } from "@/lib/auth/redirect";
import { getSession } from "@/lib/auth/session";
import { LoginForm } from "./login-form";

export default async function LoginPage() {
  const user = await getSession();
  if (user) redirect(homeFor(user));
  if (!hasAnyUser(db)) redirect("/setup");
  return <LoginForm />;
}
