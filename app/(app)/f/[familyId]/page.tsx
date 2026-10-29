import Link from "next/link";
import { AlertTriangle, CheckCircle2 } from "lucide-react";
import { db } from "@/lib/db";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { type CalendarSummary, calendarSummary } from "@/lib/calendar/summary";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { PageHeader } from "@/components/page-header";
import { MODULES } from "@/components/shell/modules";

export const dynamic = "force-dynamic";

export default async function FamilyOverviewPage({ params }: { params: Promise<{ familyId: string }> }) {
  const { familyId } = await params;
  const { family } = await requireFamily(familyId);
  const { t, locale } = await getI18n();
  const today = new Date().toISOString().slice(0, 10);
  const calendar = await calendarSummary(db, familyId, today);
  return (
    <>
      <PageHeader title={t("home.welcome", { family: family.name })} description={t("home.intro")} />
      <div className="grid gap-4 sm:grid-cols-2">
        {MODULES.map(({ key, icon: Icon, ready }) => (
          <Link key={key} href={`/f/${familyId}/${key}`} className="group">
            <Card className="h-full transition-colors group-hover:border-primary">
              <CardHeader>
                <CardTitle className="flex items-center gap-2 text-lg">
                  <Icon className="size-5 text-primary" /> {t(`nav.${key}`)}
                  {!ready && (
                    <span className="ml-auto rounded bg-muted px-2 py-0.5 text-xs font-normal text-muted-foreground">
                      {t("common.comingSoon")}
                    </span>
                  )}
                </CardTitle>
                <CardDescription>{t(`modules.${key}`)}</CardDescription>
              </CardHeader>
              {key === "calendar" && (
                <CardContent>
                  <CalendarCard summary={calendar} t={t} locale={locale} />
                </CardContent>
              )}
            </Card>
          </Link>
        ))}
      </div>
    </>
  );
}

function CalendarCard({
  summary,
  t,
  locale,
}: {
  summary: CalendarSummary;
  t: (key: string, vars?: Record<string, string | number>) => string;
  locale: string;
}) {
  const fmt = new Intl.DateTimeFormat(locale, { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
  const day = (d: string) => fmt.format(new Date(d + "T00:00:00Z"));
  return (
    <div className="space-y-3 text-sm">
      {summary.nextGap ? (
        <p className="flex items-center gap-2 font-medium text-gap">
          <AlertTriangle className="size-4 shrink-0" /> {t("calendar.overview.nextGap", { date: day(summary.nextGap) })}
        </p>
      ) : (
        <p className="flex items-center gap-2 text-ok">
          <CheckCircle2 className="size-4 shrink-0" /> {t("calendar.overview.allCovered")}
        </p>
      )}
      <div>
        <p className="mb-1.5 text-xs font-semibold tracking-wide text-muted-foreground uppercase">
          {t("calendar.overview.upcoming")}
        </p>
        {summary.upcoming.length ? (
          <ul className="space-y-1">
            {summary.upcoming.map((u) => (
              <li key={u.name + u.from} className="flex items-center gap-2">
                <span className="size-3 shrink-0 rounded-sm" style={{ backgroundColor: u.color }} aria-hidden />
                <span className="min-w-0 flex-1 truncate">{u.name}</span>
                <span className="shrink-0 text-muted-foreground tabular-nums">
                  {u.from === u.to ? day(u.from) : `${day(u.from)} – ${day(u.to)}`}
                </span>
              </li>
            ))}
          </ul>
        ) : (
          <p className="text-muted-foreground">{t("calendar.overview.nothing")}</p>
        )}
      </div>
    </div>
  );
}
