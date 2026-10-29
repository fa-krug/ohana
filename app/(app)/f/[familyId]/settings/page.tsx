import { db } from "@/lib/db";
import { getAppUrl } from "@/lib/auth/config";
import { listInvites } from "@/lib/families/invites";
import { listMembers } from "@/lib/families/members";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { PageHeader } from "@/components/page-header";
import { FamilySettings } from "@/components/families/family-settings";
import { type SettingsTab, SettingsTabs } from "@/components/families/settings-tabs";

export const dynamic = "force-dynamic";

const TABS: SettingsTab[] = ["general", "calendar", "feed"];

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
  return (
    <>
      <PageHeader title={t("settings.title")} />
      <SettingsTabs
        familyId={family.id}
        tab={tab}
        year={year}
        readOnly={role !== "editor"}
        appUrl={getAppUrl()}
        general={
          <FamilySettings
            family={{ id: family.id, name: family.name }}
            role={role}
            selfId={user.id}
            members={listMembers(db, { id: user.id }, familyId)}
            invites={
              role === "editor"
                ? listInvites(db, { id: user.id }, familyId, now).map((i) => ({
                    id: i.id,
                    url: `${getAppUrl()}/invite/${i.code}`,
                    role: i.role,
                    expiresAt: i.expiresAt,
                  }))
                : []
            }
          />
        }
      />
    </>
  );
}
