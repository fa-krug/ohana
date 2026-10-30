"use client";

import { useTransition } from "react";
import { useRouter } from "next/navigation";
import { useT } from "@/lib/i18n/provider";
import { toast } from "@/components/ui/sonner";
import { renewIterationAction, nextIterationAction } from "@/app/actions/meals";
import { useMeals } from "../meals-context";

export function RenewButton({ iterationId }: { iterationId: string }) {
  const { t } = useT();
  const { familyId } = useMeals();
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  return (
    <button
      type="button"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const res = await renewIterationAction(familyId, iterationId);
          if (res.ok) router.refresh();
          else toast.error(t("meals.common.errorRetry"));
        })
      }
      className="rounded border border-primary/50 px-3 py-1 text-xs text-primary hover:bg-primary/10 disabled:cursor-not-allowed disabled:opacity-50"
    >
      {t("meals.plan.renew")}
    </button>
  );
}

export function NextIterationButton({ className }: { className?: string }) {
  const { t } = useT();
  const { familyId } = useMeals();
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  return (
    <button
      type="button"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const res = await nextIterationAction(familyId);
          if (res.ok) router.refresh();
          else toast.error(t("meals.common.errorRetry"));
        })
      }
      className={
        className ??
        "rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground disabled:opacity-50"
      }
    >
      {t("meals.plan.nextIteration")}
    </button>
  );
}
