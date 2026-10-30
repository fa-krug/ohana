"use client";

import { useTransition } from "react";
import { useRouter } from "next/navigation";
import { RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { toast } from "@/components/ui/sonner";
import { cn } from "@/lib/utils";
import { useT } from "@/lib/i18n/provider";
import { runSearchNowAction } from "@/app/actions/appointments";

/** Queues a run for the worker; spins while it's queued or running. */
export function RunNowButton({
  familyId,
  searchId,
  busy,
  className,
  size,
}: {
  familyId: string;
  searchId: string;
  busy: boolean;
  className?: string;
  size?: "sm" | "default";
}) {
  const { t } = useT();
  const router = useRouter();
  const [pending, start] = useTransition();
  const spinning = pending || busy;

  function onRun() {
    start(async () => {
      const res = await runSearchNowAction(familyId, searchId);
      if (!res.ok) return void toast.error(res.message);
      toast.success(t("appointments.runQueued"));
      router.refresh();
    });
  }

  return (
    <Button onClick={onRun} disabled={spinning} className={className} size={size}>
      <RefreshCw className={cn("size-4", spinning && "animate-spin")} />
      {/* Both labels stacked so the button keeps its width. */}
      <span className="grid">
        <span className={cn("col-start-1 row-start-1", spinning && "invisible")}>{t("appointments.runNow")}</span>
        <span className={cn("col-start-1 row-start-1", !spinning && "invisible")} aria-hidden={!spinning}>
          {t("appointments.running")}
        </span>
      </span>
    </Button>
  );
}
