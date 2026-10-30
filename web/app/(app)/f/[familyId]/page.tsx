import Link from "next/link";
import {
  AlertTriangle,
  Banknote,
  CheckCircle2,
  ChevronRight,
  Clock,
  Luggage,
  ShoppingCart,
  Stethoscope,
  Sun,
  UtensilsCrossed,
} from "lucide-react";
import { db } from "@/lib/db";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { familyDashboard, type UpcomingItem } from "@/lib/families/dashboard";
import type { PublicEvent } from "@/lib/calendar/events";
import type { TVars } from "@/lib/i18n/translate";
import { FinanceOverviewCard } from "@/components/finance/overview-card";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { PageHeader } from "@/components/page-header";
import { MODULES } from "@/components/shell/modules";

export const dynamic = "force-dynamic";

type TFn = (key: string, vars?: TVars) => string;

/** The family overview: one dashboard over all modules (phase 7). */
export default async function FamilyOverviewPage({ params }: { params: Promise<{ familyId: string }> }) {
  const { familyId } = await params;
  const { family } = await requireFamily(familyId);
  const { t, locale } = await getI18n();
  const today = new Date().toISOString().slice(0, 10);
  const d = await familyDashboard(db, familyId, today);
  const base = `/f/${familyId}`;
  const dayFmt = new Intl.DateTimeFormat(locale, { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
  const day = (s: string) => dayFmt.format(new Date(`${s}T00:00:00Z`));
  const { today: meal, shopping } = d.meals;

  return (
    <>
      <PageHeader title={t("home.welcome", { family: family.name })} description={t("home.intro")} />
      <nav aria-label={t("home.modules")} className="-mt-2 mb-5 flex flex-wrap gap-2">
        {MODULES.map(({ key, icon: Icon }) => (
          <Link
            key={key}
            href={`${base}/${key}`}
            title={t(`modules.${key}`)}
            className="inline-flex items-center gap-1.5 rounded-full border bg-card px-3 py-1.5 text-sm font-medium shadow-xs transition-colors hover:border-primary hover:text-primary"
          >
            <Icon className="size-4 text-primary" /> {t(`nav.${key}`)}
          </Link>
        ))}
      </nav>

      <div className="grid gap-4 lg:grid-cols-3">
        {/* Today and what comes up: calendar, booked appointments, today's meal. */}
        <Card className="lg:col-span-2">
          <SectionHeader icon={Sun} title={`${t("home.today")} · ${day(today)}`} href={`${base}/calendar`} t={t} />
          <CardContent className="space-y-4 p-4 pt-0 text-sm sm:px-6 sm:pb-6">
            <ul className="space-y-2">
              <li>
                <Link
                  href={meal ? `${base}/meals/recipes/${meal.recipeId}` : `${base}/meals/plan`}
                  className="flex items-center gap-2.5 rounded-lg border p-2.5 hover:border-primary"
                >
                  {d.awayToday.length && !meal ? (
                    <>
                      <Luggage className="size-4 shrink-0 text-muted-foreground" />
                      <span className="min-w-0 flex-1 truncate text-muted-foreground">
                        {t("meals.plan.away", { types: d.awayToday.join(", ") })}
                      </span>
                    </>
                  ) : (
                    <>
                      <UtensilsCrossed className="size-4 shrink-0 text-primary" />
                      <span className="min-w-0 flex-1 truncate">
                        {meal ? (
                          <>
                            <span className="font-medium">{meal.recipeTitle}</span>
                            {meal.isLeftover && <span className="ml-1.5 text-xs text-muted-foreground">({t("meals.plan.leftover")})</span>}
                          </>
                        ) : (
                          <span className="text-muted-foreground">{t("meals.overview.nothingPlanned")}</span>
                        )}
                      </span>
                    </>
                  )}
                </Link>
              </li>
              {d.todayEvents.map((e) => (
                <li key={e.id}>
                  <EventRow event={e} base={base} />
                </li>
              ))}
            </ul>
            {d.calendar.nextGap ? (
              <p className="flex items-center gap-2 font-medium text-gap">
                <AlertTriangle className="size-4 shrink-0" /> {t("calendar.overview.nextGap", { date: day(d.calendar.nextGap) })}
              </p>
            ) : (
              <p className="flex items-center gap-2 text-ok">
                <CheckCircle2 className="size-4 shrink-0" /> {t("calendar.overview.allCovered")}
              </p>
            )}
            {d.birthdays.length > 0 && (
              <div>
                <p className="mb-1.5 text-xs font-semibold tracking-wide text-muted-foreground uppercase">{t("home.birthdays")}</p>
                <ul className="divide-y">
                  {d.birthdays.map((b) => (
                    <li key={`${b.name}|${b.day}`} className="flex items-center gap-2 py-1.5">
                      <span className="min-w-0 flex-1 truncate">
                        <span aria-hidden>🎂</span> {t("home.birthdayTurns", { name: b.name, age: b.age })}
                      </span>
                      <span className={`shrink-0 tabular-nums ${b.day === today ? "font-medium text-primary" : "text-muted-foreground"}`}>
                        {b.day === today ? t("home.today") : day(b.day)}
                      </span>
                    </li>
                  ))}
                </ul>
              </div>
            )}
            <div>
              <p className="mb-1.5 text-xs font-semibold tracking-wide text-muted-foreground uppercase">
                {t("calendar.overview.upcoming")}
              </p>
              {d.upcoming.length ? (
                <ul className="divide-y">
                  {d.upcoming.map((u) => (
                    <UpcomingRow key={u.kind === "event" ? u.event.id : `${u.name}|${u.date}`} item={u} day={day} base={base} />
                  ))}
                </ul>
              ) : (
                <p className="text-muted-foreground">{t("calendar.overview.nothing")}</p>
              )}
            </div>
          </CardContent>
        </Card>

        <div className="grid content-start gap-4">
          <Card>
            <SectionHeader
              icon={ShoppingCart}
              title={t("meals.overview.shopping")}
              href={shopping ? `${base}/meals/shopping/${shopping.id}` : `${base}/meals/shopping`}
              t={t}
            />
            <CardContent className="p-4 pt-0 text-sm sm:px-6 sm:pb-6">
              {shopping?.shoppingDate && <p className="text-xs text-muted-foreground">{day(shopping.shoppingDate)}</p>}
              <p className="mt-0.5 font-medium">
                {!shopping || shopping.total === 0 ? (
                  <span className="text-muted-foreground">{t("meals.overview.noList")}</span>
                ) : shopping.open === 0 ? (
                  t("meals.overview.allBought")
                ) : (
                  t("meals.overview.toBuy", { open: shopping.open, total: shopping.total })
                )}
              </p>
              {shopping && shopping.total > 0 && (
                <div className="mt-2 h-1.5 overflow-hidden rounded-full bg-muted" aria-hidden>
                  <div
                    className="h-full rounded-full bg-primary"
                    style={{ width: `${Math.round(((shopping.total - shopping.open) / shopping.total) * 100)}%` }}
                  />
                </div>
              )}
            </CardContent>
          </Card>
          <Card>
            <SectionHeader icon={Banknote} title={t("nav.finance")} href={`${base}/finance`} t={t} />
            <CardContent className="p-4 pt-0 sm:px-6 sm:pb-6">
              <FinanceOverviewCard summary={d.finance} t={t} locale={locale} />
            </CardContent>
          </Card>
        </div>

        {/* The appointment searches' latest finds. */}
        <Card className="lg:col-span-3">
          <SectionHeader icon={Stethoscope} title={t("home.searches")} href={`${base}/appointments`} t={t} />
          <CardContent className="p-4 pt-0 text-sm sm:px-6 sm:pb-6">
            {d.searches.length === 0 ? (
              <p className="text-muted-foreground">{t("home.noSearches")}</p>
            ) : (
              <ul className="grid gap-2 sm:grid-cols-2">
                {d.searches.slice(0, 6).map((s) => (
                  <li key={s.id}>
                    <Link
                      href={s.first ? `${base}/appointments/${s.id}/slots/${s.first.resultId}` : `${base}/appointments/${s.id}`}
                      className="flex items-center gap-3 rounded-lg border p-2.5 hover:border-primary"
                    >
                      <div className="min-w-0 flex-1">
                        <p className="flex items-center gap-2 font-medium">
                          <span className="truncate">{s.name}</span>
                          {!s.enabled && (
                            <span className="shrink-0 rounded-full bg-muted px-2 py-0.5 text-xs font-normal text-muted-foreground">
                              {t("appointments.status.paused")}
                            </span>
                          )}
                        </p>
                        <p className="truncate text-xs text-muted-foreground">
                          {s.first
                            ? s.doctors > 1
                              ? t("home.searchFirst", { doctor: s.first.doctorName, count: s.doctors - 1 })
                              : s.first.doctorName
                            : s.enabled
                              ? t("home.searchNothing")
                              : t("appointments.schedule.disabled")}
                        </p>
                      </div>
                      {s.first && (
                        <span className="shrink-0 text-right text-xs font-medium text-primary tabular-nums">
                          {new Intl.DateTimeFormat(locale, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }).format(
                            new Date(s.first.slot),
                          )}
                        </span>
                      )}
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </CardContent>
        </Card>
      </div>
    </>
  );
}

function SectionHeader({
  icon: Icon,
  title,
  href,
  t,
}: {
  icon: React.ComponentType<{ className?: string }>;
  title: string;
  href: string;
  t: TFn;
}) {
  return (
    <CardHeader className="flex-row items-center justify-between space-y-0 p-4 sm:px-6">
      <CardTitle className="flex min-w-0 items-center gap-2 text-base">
        <Icon className="size-5 shrink-0 text-primary" /> <span className="truncate">{title}</span>
      </CardTitle>
      <Link
        href={href}
        className="-mr-1 inline-flex shrink-0 items-center gap-0.5 rounded-md px-1.5 py-1 text-xs font-medium text-primary hover:bg-accent"
      >
        {t("home.open")} <ChevronRight className="size-3.5" />
      </Link>
    </CardHeader>
  );
}

function eventLabel(e: PublicEvent) {
  return e.person ? `${e.title} · ${e.person}` : e.title;
}

function EventRow({ event: e, base }: { event: PublicEvent; base: string }) {
  return (
    <Link
      href={e.searchId ? `${base}/appointments` : `${base}/calendar`}
      className="flex items-center gap-2.5 rounded-lg border p-2.5 hover:border-primary"
    >
      <Clock className="size-4 shrink-0 text-primary" />
      <span className="w-11 shrink-0 font-medium tabular-nums">{e.start ?? ""}</span>
      <span className="min-w-0 flex-1 truncate">{eventLabel(e)}</span>
    </Link>
  );
}

function UpcomingRow({ item: u, day, base }: { item: UpcomingItem; day: (d: string) => string; base: string }) {
  if (u.kind === "event") {
    const e = u.event;
    return (
      <li className="flex items-center gap-2 py-1.5">
        <Clock className="size-3 shrink-0 text-primary" aria-hidden />
        <Link href={e.searchId ? `${base}/appointments` : `${base}/calendar`} className="min-w-0 flex-1 truncate hover:underline">
          {eventLabel(e)}
        </Link>
        <span className="shrink-0 text-muted-foreground tabular-nums">
          {day(e.date)}
          {e.start ? `, ${e.start}` : ""}
        </span>
      </li>
    );
  }
  return (
    <li className="flex items-center gap-2 py-1.5">
      <span className="size-3 shrink-0 rounded-sm" style={{ backgroundColor: u.color }} aria-hidden />
      <span className="min-w-0 flex-1 truncate">{u.name}</span>
      <span className="shrink-0 text-muted-foreground tabular-nums">
        {u.date === u.to ? day(u.date) : `${day(u.date)} – ${day(u.to)}`}
      </span>
    </li>
  );
}
