import { requireFamily } from "@/lib/families/page";
import { MealsProvider } from "@/components/meals/meals-context";
import { MealsTabs } from "@/components/meals/meals-tabs";
import { OfflineIndicator } from "@/components/meals/offline-indicator";
import { ServiceWorkerRegistration } from "@/components/meals/service-worker-registration";

export default async function MealsLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ familyId: string }>;
}) {
  const { familyId } = await params;
  const { role } = await requireFamily(familyId);
  return (
    <MealsProvider familyId={familyId} canEdit={role === "editor"}>
      <ServiceWorkerRegistration />
      <OfflineIndicator />
      <div className="mx-auto flex w-full max-w-3xl flex-col">
        <MealsTabs />
        {children}
      </div>
    </MealsProvider>
  );
}
