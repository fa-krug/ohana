import { db } from "@/lib/db";
import { getAppUrl } from "@/lib/auth/config";
import { listInvites } from "@/lib/families/invites";
import { listMembers } from "@/lib/families/members";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { PageHeader } from "@/components/page-header";
import { FamilySettings } from "@/components/families/family-settings";

export const dynamic = "force-dynamic";

export default async function SettingsPage({ params }: { params: Promise<{ familyId: string }> }) {
  const { familyId } = await params;
  const { user, family, role } = await requireFamily(familyId);
  const now = new Date();
  const { t } = await getI18n();
  return (
    <>
      <PageHeader title={t("settings.title")} />
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
    </>
  );
}
