"use client";

import { useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { History, Pencil, Trash2, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import type { SearchListItem } from "@/lib/appointments/serialize";
import { criteriaSummary, scheduleSummary } from "@/lib/appointments/summary";
import { deleteSearchAction, unignoreEntryAction } from "@/app/actions/appointments";
import { AppointmentCard } from "./appointment-card";
import { RunNowButton } from "./run-now-button";
import { isBusy } from "./search-list";
import { Pill, StatusBadge } from "./status-badge";
import { useRunRefresh } from "./use-auto-refresh";
import { formatSlot } from "./format";

export function SearchDetail({ familyId, search, canEdit }: { familyId: string; search: SearchListItem; canEdit: boolean }) {
  const { t, locale } = useT();
  const router = useRouter();
  const [pending, start] = useTransition();
  const busy = isBusy(search);
  useRunRefresh(busy);
  const run = search.latestRun;
  const base = `/f/${familyId}/appointments`;
  const href = `${base}/${search.id}`;

  function onDelete() {
    if (!window.confirm(t("appointments.deleteConfirm", { name: search.name }))) return;
    start(async () => {
      const res = await deleteSearchAction(familyId, search.id);
      if (!res.ok) return void toast.error(res.message);
      toast.success(t("appointments.deleted"));
      router.push(base);
    });
  }

  function onUnignore(id: number) {
    start(async () => {
      const res = await unignoreEntryAction(familyId, id);
      if (!res.ok) return void toast.error(res.message);
      toast.success(t("appointments.unignored"));
      router.refresh();
    });
  }

  return (
    <div className="space-y-4">
      <Card>
        <CardHeader className="gap-4 p-4 sm:flex-row sm:items-start sm:justify-between sm:p-6">
          <div className="min-w-0 space-y-1.5">
            <div className="flex flex-wrap items-center gap-2">
              <h1 className="break-words text-xl font-semibold sm:text-2xl">{search.name}</h1>
              {search.runRequested ? <StatusBadge status="QUEUED" /> : run && <StatusBadge status={run.status} />}
              {!search.enabled && <Pill className="bg-muted text-muted-foreground">{t("appointments.status.paused")}</Pill>}
            </div>
            <p className="break-words text-sm text-muted-foreground">{criteriaSummary(search, t)}</p>
            <p className="text-xs text-muted-foreground" suppressHydrationWarning>
              {scheduleSummary(search, t)}
              {search.enabled && search.nextRunAt && ` · ${t("appointments.nextRun", { date: formatSlot(search.nextRunAt, locale) })}`}
            </p>
          </div>
          <div className="flex flex-col gap-2 sm:shrink-0 sm:flex-row sm:flex-wrap sm:justify-end">
            {canEdit && <RunNowButton familyId={familyId} searchId={search.id} busy={busy} className="w-full sm:w-auto" />}
            <div className="grid grid-cols-[1fr_1fr_auto] gap-2 sm:flex">
              {canEdit && (
                <Button asChild variant="outline" className="w-full sm:w-auto">
                  <Link href={`${href}/edit`}><Pencil className="size-4" /> {t("common.edit")}</Link>
                </Button>
              )}
              <Button asChild variant="ghost" className="w-full sm:w-auto">
                <Link href={`${href}/history`}><History className="size-4" /> {t("appointments.history")}</Link>
              </Button>
              {canEdit && (
                <Button size="icon" variant="ghost" onClick={onDelete} disabled={pending} aria-label={t("common.delete")} className="text-destructive hover:bg-destructive/10 hover:text-destructive">
                  <Trash2 className="size-4" />
                </Button>
              )}
            </div>
          </div>
        </CardHeader>
        <CardContent className="space-y-2 p-4 pt-0 sm:px-6">
          <p className="text-sm text-muted-foreground" suppressHydrationWarning>
            {search.lastRunAt ? t("appointments.lastRun", { date: formatSlot(search.lastRunAt, locale) }) : t("appointments.neverRun")}
            {run && run.status !== "RUNNING" && (
              <> · {t("appointments.run.found", { count: run.doctorsFound })} · {t("appointments.run.matched", { count: run.doctorsMatched })} · {t("appointments.run.slots", { count: run.slotsFound })}</>
            )}
          </p>
          {run?.errorMessage && run.status !== "RUNNING" && (
            <p className={run.status === "ERROR" ? "whitespace-pre-wrap rounded-md bg-destructive/10 p-3 text-xs text-destructive" : "whitespace-pre-wrap rounded-md bg-muted p-3 text-xs text-muted-foreground"}>
              {run.errorMessage}
            </p>
          )}
        </CardContent>
      </Card>

      <section className="space-y-2">
        <h2 className="text-sm font-semibold text-muted-foreground">{t("appointments.results")}</h2>
        {search.doctors.length === 0 ? (
          <p className="text-sm text-muted-foreground">{run ? t("appointments.noSlots") : t("appointments.notRunYet")}</p>
        ) : (
          search.doctors.map((d) => <AppointmentCard key={d.resultId} doctor={d} href={`${href}/slots/${d.resultId}`} />)
        )}
      </section>

      <Card>
        <CardHeader>
          <CardTitle className="text-lg">{t("appointments.ignored.title")}</CardTitle>
          <CardDescription>{t("appointments.ignored.hint")}</CardDescription>
        </CardHeader>
        <CardContent>
          {search.ignored.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t("appointments.ignored.none")}</p>
          ) : (
            <ul className="divide-y rounded-md border">
              {search.ignored.map((e) => (
                <li key={e.id} className="flex items-center justify-between gap-2 p-2 pl-3 text-sm">
                  <span className="min-w-0 truncate">
                    {e.doctorName || e.providerSlug}
                    {e.motiveLabel && <span className="text-muted-foreground"> · {e.motiveLabel}</span>}
                  </span>
                  {canEdit && (
                    <Button size="sm" variant="ghost" disabled={pending} onClick={() => onUnignore(e.id)}>
                      <X className="size-4" /> {t("appointments.ignored.unignore")}
                    </Button>
                  )}
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
