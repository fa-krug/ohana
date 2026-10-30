import { notFound } from "next/navigation";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { Breadcrumbs } from "@/components/breadcrumbs";
import { PageHeader } from "@/components/page-header";
import { SearchForm } from "@/components/appointments/search-form";
import { channelOptions } from "../channel-options";

export const dynamic = "force-dynamic";

export default async function NewSearchPage({ params }: { params: Promise<{ familyId: string }> }) {
  const { familyId } = await params;
  const { role } = await requireFamily(familyId);
  if (role !== "editor") notFound();
  const { t } = await getI18n();
  return (
    <div className="mx-auto max-w-2xl">
      <Breadcrumbs items={[{ label: t("nav.appointments"), href: `/f/${familyId}/appointments` }, { label: t("appointments.newSearch") }]} />
      <PageHeader title={t("appointments.newSearch")} description={t("appointments.form.description")} />
      <SearchForm familyId={familyId} channels={channelOptions(familyId)} />
    </div>
  );
}
