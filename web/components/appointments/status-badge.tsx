"use client";

import { cn } from "@/lib/utils";
import { useT } from "@/lib/i18n/provider";

const STYLES: Record<string, string> = {
  OK: "bg-primary/15 text-primary",
  NO_AVAILABILITY: "bg-muted text-muted-foreground",
  ERROR: "bg-destructive/15 text-destructive",
  RUNNING: "bg-secondary text-secondary-foreground",
  QUEUED: "bg-secondary text-secondary-foreground",
};
const KEYS: Record<string, string> = {
  OK: "appointments.status.ok",
  NO_AVAILABILITY: "appointments.status.noAvailability",
  ERROR: "appointments.status.error",
  RUNNING: "appointments.status.running",
  QUEUED: "appointments.status.queued",
};

export function Pill({ className, children }: { className?: string; children: React.ReactNode }) {
  return <span className={cn("inline-flex w-fit items-center rounded-full px-2.5 py-0.5 text-xs font-medium", className)}>{children}</span>;
}

export function StatusBadge({ status }: { status: string }) {
  const { t } = useT();
  return <Pill className={STYLES[status] ?? "bg-muted"}>{KEYS[status] ? t(KEYS[status]) : status.toLowerCase()}</Pill>;
}
