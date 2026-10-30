import { redirect } from "next/navigation";
import { db } from "@/lib/db";
import { requireUser } from "@/lib/auth/session";
import { serializeUser } from "@/lib/auth/serialize";
import { Providers } from "@/components/providers";
import { OnboardingWizard } from "./wizard";
import { getI18n } from "@/lib/i18n/server";
import { getDictionary } from "@/lib/i18n/dictionary";

export const dynamic = "force-dynamic";

export default async function OnboardingPage() {
  const user = await requireUser();
  const dto = serializeUser(db, user);
  if (dto.onboardingStep === "COMPLETED") redirect("/");
  const { locale } = await getI18n();
  const dicts = { en: getDictionary("en"), de: getDictionary("de") };
  return (
    <Providers locale={locale} dicts={dicts}>
      <main className="flex min-h-dvh flex-col items-center justify-center gap-6 bg-gradient-to-b from-primary/10 via-primary/5 to-background px-4 py-8">
        <p className="text-2xl font-semibold tracking-tight text-primary">Ohana</p>
        <OnboardingWizard step={dto.onboardingStep} />
      </main>
    </Providers>
  );
}
