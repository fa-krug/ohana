"use client";

import { Banknote, CalendarDays, House, Rss, Settings2 } from "lucide-react";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useT } from "@/lib/i18n/provider";
import { PlannerProvider } from "@/components/calendar/context";
import { CalendarSettings } from "@/components/calendar/calendar-settings";
import { FeedSettings } from "@/components/calendar/feed-settings";
import { FinanceSettings } from "@/components/finance/finance-settings";

export type SettingsTab = "general" | "household" | "calendar" | "feed" | "finance";

/** The family settings in tabs: general (name, members, invites), household (home address,
 *  notifications), the calendar's types and view, the calendar feed, and the finances. The tab
 *  is kept in the address (?tab=). */
export function SettingsTabs({
  familyId,
  tab,
  year,
  readOnly,
  appUrl,
  general,
  household,
}: {
  familyId: string;
  tab: SettingsTab;
  year: number;
  readOnly: boolean;
  appUrl: string;
  general: React.ReactNode;
  household?: React.ReactNode;
}) {
  const { t } = useT();
  function remember(next: string) {
    const url = new URL(window.location.href);
    url.searchParams.set("tab", next);
    window.history.replaceState(window.history.state, "", url);
  }
  return (
    <PlannerProvider familyId={familyId} year={year} readOnly={readOnly}>
      <Tabs defaultValue={tab} onValueChange={remember}>
        <TabsList className="flex h-auto w-full flex-wrap sm:inline-flex sm:h-10 sm:w-auto sm:flex-nowrap [&>button]:grow sm:[&>button]:grow-0 max-sm:[&_svg]:hidden">
          <TabsTrigger value="general">
            <Settings2 /> {t("settings.tabGeneral")}
          </TabsTrigger>
          {household && (
            <TabsTrigger value="household">
              <House /> {t("settings.tabHousehold")}
            </TabsTrigger>
          )}
          <TabsTrigger value="calendar">
            <CalendarDays /> {t("settings.tabCalendar")}
          </TabsTrigger>
          <TabsTrigger value="feed">
            <Rss /> {t("settings.tabFeed")}
          </TabsTrigger>
          <TabsTrigger value="finance">
            <Banknote /> {t("settings.tabFinance")}
          </TabsTrigger>
        </TabsList>
        <TabsContent value="general">{general}</TabsContent>
        {household && <TabsContent value="household">{household}</TabsContent>}
        <TabsContent value="calendar">
          <CalendarSettings />
        </TabsContent>
        <TabsContent value="feed">
          <FeedSettings appUrl={appUrl} />
        </TabsContent>
        <TabsContent value="finance">
          <FinanceSettings familyId={familyId} readOnly={readOnly} />
        </TabsContent>
      </Tabs>
    </PlannerProvider>
  );
}
