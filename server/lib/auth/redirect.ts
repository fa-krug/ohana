/**
 * Where a signed-in user goes next: the onboarding while it isn't done, else `next` (a path of
 * this site, already checked with `safeNext`) or "/". The onboarding keeps `next`, so e.g. the
 * native app's pairing page (/device/pair) still follows a first-run setup.
 */
export function homeFor(user: { onboardingStep: string }, next?: string | null): string {
  if (user.onboardingStep === "COMPLETED") return next || "/";
  return next ? `/onboarding?${new URLSearchParams({ next })}` : "/onboarding";
}
