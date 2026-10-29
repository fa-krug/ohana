import Link from "next/link";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { Card, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { PageHeader } from "@/components/page-header";
import { MODULES } from "@/components/shell/modules";
import { MealsOverviewCard } from "@/components/meals/meals-overview-card";

export default async function FamilyOverviewPage({ params }: { params: Promise<{ familyId: string }> }) {
  const { familyId } = await params;
  const { family } = await requireFamily(familyId);
  const { t } = await getI18n();
  return (
    <>
      <PageHeader title={t("home.welcome", { family: family.name })} description={t("home.intro")} />
      <div className="grid gap-4 sm:grid-cols-2">
        {MODULES.map(({ key, icon: Icon, ready }) => (
          <Link key={key} href={`/f/${familyId}/${key}`} className="group">
            <Card className="h-full transition-colors group-hover:border-primary">
              <CardHeader>
                <CardTitle className="flex items-center gap-2 text-lg">
                  <Icon className="size-5 text-primary" /> {t(`nav.${key}`)}
                  {!ready && (
                    <span className="ml-auto rounded bg-muted px-2 py-0.5 text-xs font-normal text-muted-foreground">
                      {t("common.comingSoon")}
                    </span>
                  )}
                </CardTitle>
                <CardDescription>{t(`modules.${key}`)}</CardDescription>
              </CardHeader>
            </Card>
          </Link>
        ))}
      </div>
      <div className="mt-6 grid gap-4">
        <MealsOverviewCard familyId={familyId} />
      </div>
    </>
  );
}
