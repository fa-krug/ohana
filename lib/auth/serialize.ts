import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { passkeyCredentials } from "@/lib/db/schema";
import { hasUsablePassword } from "./password";
import type { User } from "./tokens";

export interface UserDto {
  id: string;
  email: string;
  name: string;
  preferredLanguage: string;
  onboardingStep: string;
  isAdmin: boolean;
  hasPassword: boolean;
  hasPasskey: boolean;
}

export function serializeUser(db: Db, user: User): UserDto {
  const passkey = db
    .select({ id: passkeyCredentials.id })
    .from(passkeyCredentials)
    .where(eq(passkeyCredentials.userId, user.id))
    .get();
  return {
    id: user.id,
    email: user.email,
    name: user.name,
    preferredLanguage: user.preferredLanguage,
    onboardingStep: user.onboardingStep,
    isAdmin: user.isAdmin,
    hasPassword: hasUsablePassword(user.password),
    hasPasskey: passkey != null,
  };
}
