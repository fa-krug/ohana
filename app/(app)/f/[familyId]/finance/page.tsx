import { requireFamily } from "@/lib/families/page";
import { FinancePage } from "@/components/finance/finance-page";

export const dynamic = "force-dynamic";

export default async function FamilyFinancePage({ params }: { params: Promise<{ familyId: string }> }) {
  const { familyId } = await params;
  const { role } = await requireFamily(familyId);
  return <FinancePage familyId={familyId} readOnly={role !== "editor"} />;
}
