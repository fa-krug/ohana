import { requireFamily } from "@/lib/families/page";
import { CalendarPage } from "@/components/calendar/calendar-page";

export const dynamic = "force-dynamic";

export default async function FamilyCalendarPage({
  params,
  searchParams,
}: {
  params: Promise<{ familyId: string }>;
  searchParams: Promise<{ y?: string }>;
}) {
  const { familyId } = await params;
  const { role } = await requireFamily(familyId);
  const y = Number((await searchParams).y);
  const year = Number.isInteger(y) && y >= 1900 && y <= 2200 ? y : new Date().getFullYear();
  return <CalendarPage familyId={familyId} year={year} readOnly={role !== "editor"} />;
}
