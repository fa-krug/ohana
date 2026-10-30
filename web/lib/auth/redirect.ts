/** Where a signed-in user goes next. */
export function homeFor(user: { onboardingStep: string }): string {
  return user.onboardingStep === "COMPLETED" ? "/" : "/onboarding";
}
