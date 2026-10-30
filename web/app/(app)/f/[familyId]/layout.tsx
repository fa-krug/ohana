import { db } from "@/lib/db";
import { rememberFamily } from "@/lib/families/manage";
import { requireFamily } from "@/lib/families/page";

export default async function FamilyLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ familyId: string }>;
}) {
  const { familyId } = await params;
  const { user } = await requireFamily(familyId);
  if (user.lastFamilyId !== familyId) rememberFamily(db, user.id, familyId);
  return children;
}
