import { db } from "@/lib/db";
import { getAppUrl } from "@/lib/auth/config";
import { listInvites } from "@/lib/families/invites";
import { listMembers } from "@/lib/families/members";
import { listPeople } from "@/lib/families/people";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { PageHeader } from "@/components/page-header";
import { FamilySettings } from "@/components/families/family-settings";
import { type SettingsTab, SettingsTabs } from "@/components/families/settings-tabs";
import { HomeAddressCard } from "@/components/families/home-address-card";
import { NotificationsCard } from "@/components/families/notifications-card";
import { listChannels } from "@/lib/notifications/channels";
import { getPrefs } from "@/lib/notifications/prefs";
import { NotificationEventsCard } from "@/components/families/notification-events-card";

export const dynamic = "force-dynamic";

const TABS: SettingsTab[] = ["general", "household", "calendar", "feed", "finance", "ai"];

export default async function SettingsPage({
  params,
  searchParams,
}: {
  params: Promise<{ familyId: string }>;
  searchParams: Promise<{ tab?: string; y?: string }>;
}) {
  const { familyId } = await params;
  const query = await searchParams;
  const tab = TABS.find((x) => x === query.tab) ?? "general";
  const y = Number(query.y);
  const year = Number.isInteger(y) && y >= 1900 && y <= 2200 ? y : new Date().getFullYear();
  const { user, family, role } = await requireFamily(familyId);
  const now = new Date();
  const { t } = await getI18n();
  const appUrl = getAppUrl();
  return (
    <>
      <PageHeader title={t("settings.title")} />
      <SettingsTabs
        familyId={family.id}
        tab={tab}
        year={year}
        readOnly={role !== "editor"}
        appUrl={appUrl}
        general={
          <FamilySettings
            family={{ id: family.id, name: family.name }}
            role={role}
            selfId={user.id}
            appUrl={appUrl}
            members={listMembers(db, { id: user.id }, familyId)}
            people={listPeople(db, { id: user.id }, familyId).map((p) => ({ id: p.id, name: p.name, birthday: p.birthday }))}
            invites={
              role === "editor"
                ? listInvites(db, { id: user.id }, familyId, now).map((i) => ({
                    id: i.id,
                    url: `${appUrl}/invite/${i.code}`,
                    role: i.role,
                    personId: i.personId,
                    expiresAt: i.expiresAt,
                  }))
                : []
            }
          />
        }
        household={<HouseholdSettings familyId={family.id} userId={user.id} family={family} editor={role === "editor"} />}
      />
    </>
  );
}

/** Settings → Household: the home address (distances to practices) and, for editors, which
 *  news go where and the notification channels. */
function HouseholdSettings({
  familyId,
  userId,
  family,
  editor,
}: {
  familyId: string;
  userId: string;
  family: { homeAddress: string | null; homeLat: number | null; homeLng: number | null };
  editor: boolean;
}) {
  const channels = editor ? listChannels(db, { id: userId }, familyId) : [];
  return (
    <div className="space-y-6">
      {editor && (
        <>
          <NotificationEventsCard
            familyId={familyId}
            prefs={getPrefs(db, familyId)}
            channels={channels.map((c) => ({ id: c.id, name: c.name, enabled: c.enabled }))}
          />
          <NotificationsCard familyId={familyId} channels={channels} />
        </>
      )}
      <HomeAddressCard
        familyId={familyId}
        home={{ address: family.homeAddress, lat: family.homeLat, lng: family.homeLng }}
        editor={editor}
      />
    </div>
  );
}
