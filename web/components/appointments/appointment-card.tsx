"use client";

import Link from "next/link";
import { ChevronRight } from "lucide-react";
import { useT } from "@/lib/i18n/provider";
import type { DoctorSlot } from "@/lib/appointments/serialize";
import { formatSlot } from "./format";

/** One doctor's earliest slot; links to the slot detail page. */
export function AppointmentCard({ doctor, href }: { doctor: DoctorSlot; href: string }) {
  const { t, locale } = useT();
  const description = [doctor.practiceName, doctor.motiveLabel].filter(Boolean).join(" · ");
  return (
    <Link href={href} className="flex items-center gap-3 rounded-lg border bg-card p-3 transition-colors hover:bg-muted/50 sm:p-4">
      <div className="min-w-0 flex-1 space-y-0.5">
        <div className="truncate font-medium" title={doctor.doctorName}>{doctor.doctorName}</div>
        {description && <div className="truncate text-sm text-muted-foreground" title={description}>{description}</div>}
        <div className="text-sm">
          <span className="font-medium text-primary" suppressHydrationWarning>{formatSlot(doctor.slot, locale)}</span>
          {doctor.isNextSlot && <span className="block text-muted-foreground sm:ml-1.5 sm:inline">{t("appointments.nextAvailable")}</span>}
          <span className="ml-1.5 text-xs text-muted-foreground">· {doctor.source === "jameda" ? "jameda" : "Doctolib"}</span>
        </div>
      </div>
      <ChevronRight className="size-5 shrink-0 text-muted-foreground" />
    </Link>
  );
}
