import { Calendar } from "lucide-react";
import type { TVars } from "@/lib/i18n/translate";
import { db } from "@/lib/db";
import { getMealPlanView } from "@/lib/meals/queries/meal-plan";
import { listTags } from "@/lib/meals/queries/recipes";
import { awayDays } from "@/lib/meals/meal-plan/away";
import { EmptyState } from "@/components/ui/empty-state";
import { IterationCard } from "@/components/meals/plan/iteration-card";
import { GeneratePlanDrawer } from "@/components/meals/plan/generate-plan-drawer";
import { NextIterationButton } from "@/components/meals/plan/iteration-actions";

type PlanContentProps = {
  familyId: string;
  canEdit: boolean;
  todayIso: string;
  t: (key: string, vars?: TVars) => string;
};

/**
 * Async server component holding the meal-plan data query and the full page
 * body (including the header action row, which depends on plan data). Rendered
 * inside a <Suspense> boundary so the page paints its skeleton immediately and
 * this content streams in once the query resolves.
 */
export async function PlanContent({ familyId, canEdit, todayIso, t }: PlanContentProps) {
  const tags = listTags(db, familyId);
  const plan = getMealPlanView(db, familyId);

  if (!plan || plan.iterations.length === 0) {
    return (
      <div className="flex flex-1 flex-col gap-4">
        <h1 className="text-2xl font-bold">{t("meals.plan.title")}</h1>
        <EmptyState
          fill
          icon={Calendar}
          title={t("meals.plan.noPlanTitle")}
          subtitle={t("meals.plan.noPlanSubtitle")}
          action={canEdit && <GeneratePlanDrawer triggerLabel={t("meals.plan.setup")} tags={tags} />}
        />
      </div>
    );
  }

  const defaults = {
    iterationWeeks: plan.iterationWeeks,
    shoppingDays: plan.shoppingDays,
    servings: plan.servings,
    knownRatio: Number(plan.knownRatio),
    defaultLeftoverDays: plan.defaultLeftoverDays,
    excludedTagIds: plan.excludedTagIds,
  };

  // Days the whole family is away (calendar types marked "away"): shown instead of a meal.
  const from = plan.iterations.reduce((m, it) => (it.startDate < m ? it.startDate : m), plan.iterations[0].startDate);
  const to = plan.iterations.reduce((m, it) => (it.endDate > m ? it.endDate : m), plan.iterations[0].endDate);
  const away = Object.fromEntries(awayDays(db, familyId, from, to));

  const active = plan.iterations.find((it) => it.status === "ACTIVE") ?? null;
  const archived = plan.iterations.filter((it) => it.id !== active?.id);
  const ended = active !== null && active.endDate < todayIso;

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">{t("meals.plan.title")}</h1>
        {canEdit && (
          <GeneratePlanDrawer
            triggerLabel={t("meals.plan.updateConfig")}
            tags={tags}
            defaults={defaults}
            triggerVariant="outline"
          />
        )}
      </div>

      {ended && canEdit && (
        <div className="flex items-center justify-between rounded-lg border border-primary/30 bg-primary/10 p-3 text-sm">
          <span>{t("meals.plan.iterationEnded")}</span>
          <NextIterationButton />
        </div>
      )}

      {active && (
        <IterationCard
          iteration={active}
          shoppingDays={plan.shoppingDays}
          isArchived={false}
          todayIso={todayIso}
          away={away}
        />
      )}

      {!active && (
        <EmptyState
          icon={Calendar}
          title={t("meals.plan.noActiveTitle")}
          subtitle={t("meals.plan.noActiveSubtitle")}
          action={canEdit && <NextIterationButton />}
        />
      )}

      {archived.length > 0 && (
        <section className="space-y-3">
          <h2 className="text-lg font-semibold text-muted-foreground">{t("meals.plan.pastIterations")}</h2>
          {archived.map((it) => (
            <IterationCard
              key={it.id}
              iteration={it}
              shoppingDays={plan.shoppingDays}
              isArchived
              todayIso={todayIso}
              away={away}
            />
          ))}
        </section>
      )}
    </div>
  );
}
