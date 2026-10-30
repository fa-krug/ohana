import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { db } from "@/lib/db";
import { listTags } from "@/lib/meals/queries/recipes";
import { TagManagementClient } from "./tag-management-client";

export const dynamic = "force-dynamic";

export default async function TagSettingsPage({ params }: { params: Promise<{ familyId: string }> }) {
  const { familyId } = await params;
  await requireFamily(familyId);
  const { locale } = await getI18n();
  return <TagManagementClient tags={listTags(db, familyId)} locale={locale} />;
}
