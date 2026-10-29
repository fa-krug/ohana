import { getI18n } from "@/lib/i18n/server";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { CreateFamilyForm } from "@/components/families/create-family-form";

export default async function NewFamilyPage() {
  const { t } = await getI18n();
  return (
    <Card className="mx-auto mt-8 max-w-md">
      <CardHeader>
        <CardTitle>{t("families.newTitle")}</CardTitle>
        <CardDescription>{t("families.newDescription")}</CardDescription>
      </CardHeader>
      <CardContent>
        <CreateFamilyForm />
      </CardContent>
    </Card>
  );
}
