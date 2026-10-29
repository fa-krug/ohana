import { notFound } from "next/navigation";
import { db } from "@/lib/db";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { getSlotDetail } from "@/lib/appointments/serialize";
import { Breadcrumbs } from "@/components/breadcrumbs";
import { SlotDetail } from "@/components/appointments/slot-detail";

export const dynamic = "force-dynamic";

export default async function SlotPage({
  params,
}: {
  params: Promise<{ familyId: string; searchId: string; resultId: string }>;
}) {
  const { familyId, searchId, resultId } = await params;
  const { role } = await requireFamily(familyId);
  const id = Number(resultId);
  const data = Number.isInteger(id) ? getSlotDetail(db, familyId, searchId, id) : null;
  if (!data) notFound();
  const { t } = await getI18n();
  const base = `/f/${familyId}/appointments`;
  return (
    <div className="mx-auto max-w-2xl">
      <Breadcrumbs
        items={[
          { label: t("nav.appointments"), href: base },
          { label: data.searchName, href: `${base}/${searchId}` },
          { label: data.slot.doctorName },
        ]}
      />
      <SlotDetail familyId={familyId} data={data} canEdit={role === "editor"} />
    </div>
  );
}
