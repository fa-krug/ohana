import { notFound } from "next/navigation";
import { db } from "@/lib/db";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { getSearchDetail } from "@/lib/appointments/serialize";
import { Breadcrumbs } from "@/components/breadcrumbs";
import { PageHeader } from "@/components/page-header";
import { SearchForm } from "@/components/appointments/search-form";
import { channelOptions } from "../../channel-options";

export const dynamic = "force-dynamic";

export default async function EditSearchPage({ params }: { params: Promise<{ familyId: string; searchId: string }> }) {
  const { familyId, searchId } = await params;
  const { role } = await requireFamily(familyId);
  const search = getSearchDetail(db, familyId, searchId);
  if (!search || role !== "editor") notFound();
  const { t } = await getI18n();
  const base = `/f/${familyId}/appointments`;
  return (
    <div className="mx-auto max-w-2xl">
      <Breadcrumbs
        items={[
          { label: t("nav.appointments"), href: base },
          { label: search.name, href: `${base}/${search.id}` },
          { label: t("common.edit") },
        ]}
      />
      <PageHeader title={t("appointments.form.editTitle")} />
      <SearchForm familyId={familyId} search={search} channels={channelOptions(familyId)} />
    </div>
  );
}
