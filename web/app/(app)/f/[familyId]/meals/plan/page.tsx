import { Suspense } from "react";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { Skeleton } from "@/components/ui/skeleton";
import { MealPlanSkeleton } from "@/components/meals/plan/meal-plan-skeleton";
import { PlanContent } from "./plan-content";

export const dynamic = "force-dynamic";

export default async function PlanPage({ params }: { params: Promise<{ familyId: string }> }) {
  const { familyId } = await params;
  const { role } = await requireFamily(familyId);
  const { t } = await getI18n();
  const todayIso = new Date().toISOString().slice(0, 10);

  return (
    <Suspense
      fallback={
        <div className="space-y-4">
          <div className="flex items-center justify-between">
            <Skeleton className="h-8 w-32" />
            <Skeleton className="h-8 w-28 rounded-md" />
          </div>
          <MealPlanSkeleton />
        </div>
      }
    >
      <PlanContent familyId={familyId} canEdit={role === "editor"} todayIso={todayIso} t={t} />
    </Suspense>
  );
}
