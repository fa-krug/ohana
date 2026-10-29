"use client";

import { Banknote, CalendarDays, Database, House, Rss, Settings2, Sparkles } from "lucide-react";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useT } from "@/lib/i18n/provider";
import { PlannerProvider } from "@/components/calendar/context";
import { CalendarSettings } from "@/components/calendar/calendar-settings";
import { FeedSettings } from "@/components/calendar/feed-settings";
import { FinanceSettings } from "@/components/finance/finance-settings";
import { AiSettingsSection } from "@/components/assistant/ai-settings";
import { DataSettings } from "@/components/families/data-settings";

export type SettingsTab = "general" | "household" | "calendar" | "feed" | "finance" | "ai" | "data";

/** The family settings in tabs: general (name, members, invites), household (home address,
 *  notifications), the calendar's types and view, the calendar feed, the finances, the AI
 *  assistant, and export / import of the family. The tab is kept in the address (?tab=). */
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
        {/* Wraps onto a second row wherever the tabs don't fit (phones, or next to the
            sidebars) instead of scrolling sideways. */}
        <TabsList className="flex h-auto w-full flex-wrap sm:inline-flex sm:w-auto [&>button]:grow sm:[&>button]:grow-0 max-sm:[&_svg]:hidden">
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
          <TabsTrigger value="ai">
            <Sparkles /> {t("settings.tabAi")}
          </TabsTrigger>
          <TabsTrigger value="data">
            <Database /> {t("settings.tabData")}
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
        <TabsContent value="ai">
          <AiSettingsSection familyId={familyId} readOnly={readOnly} />
        </TabsContent>
        <TabsContent value="data">
          <DataSettings />
        </TabsContent>
      </Tabs>
    </PlannerProvider>
  );
}
