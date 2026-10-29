import { requireAdminPage } from "@/lib/auth/session";
import { getI18n } from "@/lib/i18n/server";
import { PageHeader } from "@/components/page-header";
import { AdminTabs } from "@/components/admin/admin-tabs";

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  await requireAdminPage();
  const { t } = await getI18n();
  return (
    <>
      <PageHeader title={t("admin.title")} />
      <AdminTabs />
      {children}
    </>
  );
}
