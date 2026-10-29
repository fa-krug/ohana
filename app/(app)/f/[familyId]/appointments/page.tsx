import Link from "next/link";
import { Plus } from "lucide-react";
import { db } from "@/lib/db";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { listSearchesWithLatest } from "@/lib/appointments/serialize";
import { Button } from "@/components/ui/button";
import { PageHeader } from "@/components/page-header";
import { SearchList } from "@/components/appointments/search-list";
import { BookedList } from "@/components/appointments/booked-list";
import { listBookedAppointments, publicEvent } from "@/lib/calendar/events";

export const dynamic = "force-dynamic";

export default async function AppointmentsPage({ params }: { params: Promise<{ familyId: string }> }) {
  const { familyId } = await params;
  const { role } = await requireFamily(familyId);
  const { t } = await getI18n();
  const canEdit = role === "editor";
  return (
    <>
      <PageHeader title={t("nav.appointments")} description={t("modules.appointments")}>
        {canEdit && (
          <Button asChild>
            <Link href={`/f/${familyId}/appointments/new`}><Plus className="size-4" /> {t("appointments.newSearch")}</Link>
          </Button>
        )}
      </PageHeader>
      <BookedList
        familyId={familyId}
        canEdit={canEdit}
        events={listBookedAppointments(db, familyId, new Date().toISOString().slice(0, 10)).map(publicEvent)}
      />
      <SearchList familyId={familyId} searches={listSearchesWithLatest(db, familyId)} canEdit={canEdit} />
    </>
  );
}
