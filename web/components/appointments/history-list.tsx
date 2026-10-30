"use client";

import { Card, CardContent, CardHeader } from "@/components/ui/card";
import { useT } from "@/lib/i18n/provider";
import type { RunWithResults } from "@/lib/appointments/serialize";
import { AppointmentCard } from "./appointment-card";
import { StatusBadge } from "./status-badge";
import { useRunRefresh } from "./use-auto-refresh";
import { formatSlot } from "./format";

export function HistoryList({ runs, searchHref }: { runs: RunWithResults[]; searchHref: string }) {
  const { t, locale } = useT();
  useRunRefresh(runs.some((r) => r.run.status === "RUNNING"));
  if (runs.length === 0) return <p className="text-sm text-muted-foreground">{t("appointments.run.noRuns")}</p>;
  return (
    <div className="space-y-3">
      {runs.map(({ run, doctors }) => (
        <Card key={run.id}>
          <CardHeader className="gap-2 p-4 sm:p-5">
            <div className="flex flex-wrap items-center gap-2">
              <StatusBadge status={run.status} />
              <span className="text-sm text-muted-foreground" suppressHydrationWarning>{formatSlot(run.startedAt, locale)}</span>
            </div>
            <p className="text-xs text-muted-foreground">
              {t(run.triggeredBy === "MANUAL" ? "appointments.run.manual" : "appointments.run.scheduled")} · {t("appointments.run.found", { count: run.doctorsFound })} · {t("appointments.run.matched", { count: run.doctorsMatched })} · {t("appointments.run.slots", { count: run.slotsFound })}
              {run.notified && ` · ${t("appointments.run.notified")}`}
            </p>
            {run.errorMessage && (
              <p className={run.status === "ERROR" ? "whitespace-pre-wrap rounded-md bg-destructive/10 p-3 text-xs text-destructive" : "whitespace-pre-wrap rounded-md bg-muted p-3 text-xs text-muted-foreground"}>
                {run.errorMessage}
              </p>
            )}
          </CardHeader>
          {doctors.length > 0 && (
            <CardContent className="space-y-2 p-4 pt-0 sm:px-5">
              {doctors.map((d) => <AppointmentCard key={d.resultId} doctor={d} href={`${searchHref}/slots/${d.resultId}`} />)}
            </CardContent>
          )}
        </Card>
      ))}
    </div>
  );
}
