"use client";

import { CalendarDays, Rss, Settings2 } from "lucide-react";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useT } from "@/lib/i18n/provider";
import { PlannerProvider } from "@/components/calendar/context";
import { CalendarSettings } from "@/components/calendar/calendar-settings";
import { FeedSettings } from "@/components/calendar/feed-settings";

export type SettingsTab = "general" | "calendar" | "feed";

/** The family settings in tabs: general (name, members, invites), the calendar's types and
 *  view, and the calendar feed. The tab is kept in the address (?tab=). */
export function SettingsTabs({
  familyId,
  tab,
  year,
  readOnly,
  appUrl,
  general,
}: {
  familyId: string;
  tab: SettingsTab;
  year: number;
  readOnly: boolean;
  appUrl: string;
  general: React.ReactNode;
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
        <TabsList className="flex w-full sm:inline-flex sm:w-auto [&>button]:flex-1 sm:[&>button]:flex-none max-sm:[&_svg]:hidden">
          <TabsTrigger value="general">
            <Settings2 /> {t("settings.tabGeneral")}
          </TabsTrigger>
          <TabsTrigger value="calendar">
            <CalendarDays /> {t("settings.tabCalendar")}
          </TabsTrigger>
          <TabsTrigger value="feed">
            <Rss /> {t("settings.tabFeed")}
          </TabsTrigger>
        </TabsList>
        <TabsContent value="general">{general}</TabsContent>
        <TabsContent value="calendar">
          <CalendarSettings />
        </TabsContent>
        <TabsContent value="feed">
          <FeedSettings appUrl={appUrl} />
        </TabsContent>
      </Tabs>
    </PlannerProvider>
  );
}
