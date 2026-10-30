import { db } from "@/lib/db";
import { listAllFamilies } from "@/lib/admin/families";
import { requireAdminPage } from "@/lib/auth/session";
import { AdminFamilies } from "@/components/admin/admin-families";

export const dynamic = "force-dynamic";

export default async function AdminFamiliesPage() {
  await requireAdminPage();
  return <AdminFamilies families={listAllFamilies(db)} />;
}
