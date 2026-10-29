import { db } from "@/lib/db";
import { requireAdminPage } from "@/lib/auth/session";
import { listUsers } from "@/lib/admin/users";
import { AdminUsers } from "@/components/admin/admin-users";

export const dynamic = "force-dynamic";

export default async function AdminUsersPage() {
  const me = await requireAdminPage();
  return <AdminUsers selfId={me.id} users={listUsers(db)} />;
}
