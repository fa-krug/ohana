import { notFound } from "next/navigation";
import { requireFamily } from "@/lib/families/page";
import { getI18n } from "@/lib/i18n/server";
import { db } from "@/lib/db";
import { getShoppingListById } from "@/lib/meals/queries/shopping";
import { ShoppingListView } from "@/components/meals/shopping/shopping-list-view";

export const dynamic = "force-dynamic";

export default async function ShoppingListDetailPage({ params }: { params: Promise<{ familyId: string; id: string }> }) {
  const { familyId, id } = await params;
  const { role } = await requireFamily(familyId);
  const { locale } = await getI18n();
  const list = getShoppingListById(db, familyId, id, locale);
  if (!list) notFound();
  return <ShoppingListView list={list} showDate familyId={familyId} canEdit={role === "editor"} />;
}
