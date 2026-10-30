import { Suspense } from "react";
import { requireFamily } from "@/lib/families/page";
import { resolveLocale } from "@/lib/i18n/server";
import { ShoppingListSkeleton } from "@/components/meals/shopping/shopping-list-skeleton";
import { ShoppingContent } from "./shopping-content";

export const dynamic = "force-dynamic";

export default async function ShoppingPage({ params }: { params: Promise<{ familyId: string }> }) {
  const { familyId } = await params;
  const { role } = await requireFamily(familyId);
  const locale = await resolveLocale();
  return (
    <Suspense fallback={<ShoppingListSkeleton />}>
      <ShoppingContent familyId={familyId} canEdit={role === "editor"} locale={locale} />
    </Suspense>
  );
}
