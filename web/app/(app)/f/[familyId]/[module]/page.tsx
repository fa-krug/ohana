import { notFound } from "next/navigation";
import { Construction } from "lucide-react";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { Card, CardContent } from "@/components/ui/card";
import { PageHeader } from "@/components/page-header";
import { isModule } from "@/components/shell/modules";

/** Placeholder for modules that aren't built yet; a built module has its own folder, which
 *  takes precedence over this dynamic segment. */
export default async function ModulePage({ params }: { params: Promise<{ familyId: string; module: string }> }) {
  const { familyId, module } = await params;
  await requireFamily(familyId);
  if (!isModule(module)) notFound();
  const { t } = await getI18n();
  const name = t(`nav.${module}`);
  return (
    <>
      <PageHeader title={name} description={t(`modules.${module}`)} />
      <Card>
        <CardContent className="flex flex-col items-center gap-3 py-12 text-center">
          <Construction className="size-10 text-primary" />
          <p className="font-medium">{t("modules.soonTitle", { module: name })}</p>
          <p className="max-w-md text-sm text-muted-foreground">{t("modules.soonText")}</p>
        </CardContent>
      </Card>
    </>
  );
}
