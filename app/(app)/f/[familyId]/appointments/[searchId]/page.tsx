import { notFound } from "next/navigation";
import { db } from "@/lib/db";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { getSearchDetail } from "@/lib/appointments/serialize";
import { Breadcrumbs } from "@/components/breadcrumbs";
import { SearchDetail } from "@/components/appointments/search-detail";

export const dynamic = "force-dynamic";

export default async function SearchPage({ params }: { params: Promise<{ familyId: string; searchId: string }> }) {
  const { familyId, searchId } = await params;
  const { role } = await requireFamily(familyId);
  const search = getSearchDetail(db, familyId, searchId);
  if (!search) notFound();
  const { t } = await getI18n();
  return (
    <>
      <Breadcrumbs items={[{ label: t("nav.appointments"), href: `/f/${familyId}/appointments` }, { label: search.name }]} />
      <SearchDetail familyId={familyId} search={search} canEdit={role === "editor"} />
    </>
  );
}
