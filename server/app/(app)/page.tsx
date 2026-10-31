import { redirect } from "next/navigation";
import { db } from "@/lib/db";
import { requireUser } from "@/lib/auth/session";
import { defaultFamilyId } from "@/lib/families/manage";
import { getI18n } from "@/lib/i18n/server";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { CreateFamilyForm } from "@/components/families/create-family-form";

export const dynamic = "force-dynamic";

export default async function HomePage() {
  const user = await requireUser();
  const familyId = defaultFamilyId(db, user);
  if (familyId) redirect(`/f/${familyId}`);
  const { t } = await getI18n();
  return (
    <Card className="mx-auto mt-8 max-w-md">
      <CardHeader>
        <CardTitle>{t("home.noFamilyTitle")}</CardTitle>
        <CardDescription>{t("home.noFamilyText")}</CardDescription>
      </CardHeader>
      <CardContent>
        <CreateFamilyForm />
      </CardContent>
    </Card>
  );
}
