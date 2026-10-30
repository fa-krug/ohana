import { db } from "@/lib/db";
import { requireAuth } from "@/lib/auth/session";
import { listPasskeys } from "@/lib/auth/passkey-management";
import { hasUsablePassword } from "@/lib/auth/password";
import { listTokens } from "@/lib/auth/tokens";
import { getI18n } from "@/lib/i18n/server";
import { PageHeader } from "@/components/page-header";
import { AccountClient } from "@/components/account/account-client";

export const dynamic = "force-dynamic";

export default async function AccountPage() {
  const { user, token } = await requireAuth();
  const { t } = await getI18n();
  return (
    <>
      <PageHeader title={t("account.title")} />
      <AccountClient
        name={user.name}
        email={user.email}
        hasPassword={hasUsablePassword(user.password)}
        canReset={token.canReset}
        passkeys={listPasskeys(db, user.id)}
        tokens={listTokens(db, user.id, "api").map((tk) => ({
          id: tk.id,
          name: tk.name,
          createdAt: tk.createdAt,
          lastUsedAt: tk.lastUsedAt,
        }))}
      />
    </>
  );
}
