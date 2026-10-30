import { notFound } from "next/navigation";
import { db } from "@/lib/db";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { getSearchDetail, listRunsWithResults } from "@/lib/appointments/serialize";
import { Breadcrumbs } from "@/components/breadcrumbs";
import { PageHeader } from "@/components/page-header";
import { HistoryList } from "@/components/appointments/history-list";

export const dynamic = "force-dynamic";

export default async function HistoryPage({ params }: { params: Promise<{ familyId: string; searchId: string }> }) {
  const { familyId, searchId } = await params;
  await requireFamily(familyId);
  const search = getSearchDetail(db, familyId, searchId);
  if (!search) notFound();
  const { t } = await getI18n();
  const base = `/f/${familyId}/appointments`;
  return (
    <>
      <Breadcrumbs
        items={[
          { label: t("nav.appointments"), href: base },
          { label: search.name, href: `${base}/${search.id}` },
          { label: t("appointments.history") },
        ]}
      />
      <PageHeader title={t("appointments.history")} description={t("appointments.historyHint")} />
      <HistoryList runs={listRunsWithResults(db, familyId, searchId)} searchHref={`${base}/${search.id}`} />
    </>
  );
}
