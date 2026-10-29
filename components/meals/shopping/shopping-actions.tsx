"use client";

import { useTransition } from "react";
import { useRouter } from "next/navigation";
import { useT } from "@/lib/i18n/provider";
import { toast } from "@/components/ui/sonner";
import { submitUncheckAll } from "@/lib/offline/submit";
import { useMeals } from "../meals-context";

export function UncheckAllButton({ itemIds }: { itemIds: string[] }) {
  const { t } = useT();
  const { familyId } = useMeals();
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  return (
    <button
      type="button"
      disabled={pending || itemIds.length === 0}
      onClick={() =>
        startTransition(async () => {
          const res = await submitUncheckAll(familyId, itemIds);
          if (res === "error") {
            toast.error(t("meals.common.errorRetry"));
          } else {
            router.refresh();
          }
        })
      }
      className="text-sm font-medium text-primary hover:underline disabled:cursor-not-allowed disabled:text-muted-foreground disabled:no-underline"
    >
      {t("meals.shopping.uncheckAll")}
    </button>
  );
}
