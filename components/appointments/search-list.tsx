"use client";

import Link from "next/link";
import { AlertTriangle, ChevronRight, Plus, Stethoscope } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader } from "@/components/ui/card";
import { cn } from "@/lib/utils";
import { useT } from "@/lib/i18n/provider";
import type { SearchListItem } from "@/lib/appointments/serialize";
import { criteriaSummary, scheduleSummary } from "@/lib/appointments/summary";
import { AppointmentCard } from "./appointment-card";
import { RunNowButton } from "./run-now-button";
import { Pill, StatusBadge } from "./status-badge";
import { useRunRefresh } from "./use-auto-refresh";
import { formatSlot } from "./format";

/** How many doctors a search card shows inline. */
const INLINE = 3;

export function isBusy(s: SearchListItem): boolean {
  return s.runRequested || s.latestRun?.status === "RUNNING";
}

export function SearchList({ familyId, searches, canEdit }: { familyId: string; searches: SearchListItem[]; canEdit: boolean }) {
  const { t } = useT();
  useRunRefresh(searches.some(isBusy));
  const base = `/f/${familyId}/appointments`;

  if (searches.length === 0) {
    return (
      <Card>
        <CardContent className="flex flex-col items-center gap-3 py-12 text-center">
          <Stethoscope className="size-10 text-primary" />
          <p className="font-medium">{t("appointments.noSearches")}</p>
          <p className="max-w-md text-sm text-muted-foreground">{t("appointments.noSearchesHint")}</p>
          {canEdit && (
            <Button asChild className="mt-2">
              <Link href={`${base}/new`}><Plus className="size-4" /> {t("appointments.newSearch")}</Link>
            </Button>
          )}
        </CardContent>
      </Card>
    );
  }

  return (
    <div className="space-y-4">
      {searches.map((s) => (
        <SearchCard key={s.id} search={s} base={base} familyId={familyId} canEdit={canEdit} />
      ))}
    </div>
  );
}

function SearchCard({ search, base, familyId, canEdit }: { search: SearchListItem; base: string; familyId: string; canEdit: boolean }) {
  const { t, locale } = useT();
  const run = search.latestRun;
  const busy = isBusy(search);
  const href = `${base}/${search.id}`;
  const shown = search.doctors.slice(0, INLINE);
  const more = search.doctors.length - shown.length;

  return (
    <Card className={cn(run?.status === "ERROR" && !busy && "border-destructive/50")}>
      <CardHeader className="gap-3 p-4 sm:flex-row sm:items-start sm:justify-between sm:p-5">
        <div className="min-w-0 space-y-1.5">
          <Link href={href} className="group flex min-w-0 items-center gap-2">
            {run?.status === "ERROR" && !busy && <AlertTriangle className="size-5 shrink-0 text-destructive" />}
            <h2 className="truncate text-lg font-semibold group-hover:underline" title={search.name}>{search.name}</h2>
          </Link>
          <p className="break-words text-sm text-muted-foreground">{criteriaSummary(search, t)}</p>
          <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
            {search.runRequested ? <StatusBadge status="QUEUED" /> : run && <StatusBadge status={run.status} />}
            {!search.enabled && <Pill className="bg-muted text-muted-foreground">{t("appointments.status.paused")}</Pill>}
            <span suppressHydrationWarning>
              {scheduleSummary(search, t)} ·{" "}
              {search.lastRunAt ? t("appointments.lastRun", { date: formatSlot(search.lastRunAt, locale) }) : t("appointments.neverRun")}
            </span>
          </div>
        </div>
        <div className="flex gap-2 sm:shrink-0">
          {canEdit && <RunNowButton familyId={familyId} searchId={search.id} busy={busy} size="sm" className="flex-1 sm:flex-none" />}
          <Button asChild variant="outline" size="sm" className="flex-1 sm:flex-none">
            <Link href={href}>{t("appointments.open")} <ChevronRight className="size-4" /></Link>
          </Button>
        </div>
      </CardHeader>
      <CardContent className="space-y-2 p-4 pt-0 sm:px-5 sm:pb-5">
        {run?.status === "ERROR" && run.errorMessage && !busy && (
          <p className="line-clamp-3 whitespace-pre-wrap rounded-md bg-destructive/10 p-2 text-xs text-destructive">{run.errorMessage}</p>
        )}
        {shown.length === 0 ? (
          <p className="text-sm text-muted-foreground">{run ? t("appointments.noSlots") : t("appointments.notRunYet")}</p>
        ) : (
          <>
            {shown.map((d) => (
              <AppointmentCard key={d.resultId} doctor={d} href={`${href}/slots/${d.resultId}`} />
            ))}
            {more > 0 && (
              <Link href={href} className="block pt-1 text-sm text-primary hover:underline">
                {t("appointments.moreResults", { count: more })}
              </Link>
            )}
          </>
        )}
      </CardContent>
    </Card>
  );
}
