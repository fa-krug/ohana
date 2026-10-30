import { eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { users } from "@/lib/db/schema";

/**
 * Where a new account stands:
 * - SET_CREDENTIALS: made by an admin, opened with a setup link; needs a passkey or a password.
 * - ADD_PASSKEY: has a password; a passkey is offered (can be skipped).
 * - COMPLETED: everything else. A user without a family is asked to create one on "/".
 */
export const ONBOARDING_STEPS = ["SET_CREDENTIALS", "ADD_PASSKEY", "COMPLETED"] as const;
export type OnboardingStep = (typeof ONBOARDING_STEPS)[number];

export function setStep(db: Db, userId: string, step: OnboardingStep): void {
  db.update(users).set({ onboardingStep: step }).where(eq(users.id, userId)).run();
}

/** Moves on after a passkey was added (or skipped). */
export function afterPasskey(db: Db, user: { id: string; onboardingStep: string }): void {
  if (user.onboardingStep !== "COMPLETED") setStep(db, user.id, "COMPLETED");
}

/** Moves on after a password was set: offer a passkey next. */
export function afterPassword(db: Db, user: { id: string; onboardingStep: string }): void {
  if (user.onboardingStep === "SET_CREDENTIALS") setStep(db, user.id, "ADD_PASSKEY");
}
