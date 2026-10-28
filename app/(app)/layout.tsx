import { redirect } from "next/navigation";
import { db } from "@/lib/db";
import { requireUser } from "@/lib/auth/session";
import { defaultFamilyId, listFamiliesOf } from "@/lib/families/manage";
import { Providers } from "@/components/providers";
import { AppShell } from "@/components/shell/app-shell";
import { getI18n } from "@/lib/i18n/server";
import { getDictionary } from "@/lib/i18n/dictionary";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const user = await requireUser();
  if (user.onboardingStep !== "COMPLETED") redirect("/onboarding");
  const { locale } = await getI18n();
  const dicts = { en: getDictionary("en"), de: getDictionary("de") };
  const families = listFamiliesOf(db, user.id).map(({ id, name, role }) => ({ id, name, role }));
  return (
    <Providers locale={locale} dicts={dicts}>
      <AppShell
        user={{ name: user.name, email: user.email, isAdmin: user.isAdmin }}
        families={families}
        defaultFamilyId={defaultFamilyId(db, user)}
      >
        {children}
      </AppShell>
    </Providers>
  );
}
