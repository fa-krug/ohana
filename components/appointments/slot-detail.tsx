"use client";

import { useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ExternalLink, EyeOff, Search as SearchIcon } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import type { SlotDetailData } from "@/lib/appointments/serialize";
import { formatDistanceKm, haversineKm } from "@/lib/appointments/distance";
import { googleSearchUrl } from "@/lib/appointments/google-search";
import { ignoreResultAction } from "@/app/actions/appointments";
import { Pill } from "./status-badge";
import { formatSlot } from "./format";

export function SlotDetail({ familyId, data, canEdit }: { familyId: string; data: SlotDetailData; canEdit: boolean }) {
  const { t, locale } = useT();
  const router = useRouter();
  const [pending, start] = useTransition();
  const s = data.slot;
  const unknown = t("appointments.slot.unknown");
  const searchHref = `/f/${familyId}/appointments/${data.searchId}`;

  // Scraped data: only ever link to http(s).
  const bookingUrl = /^https?:\/\//i.test(s.bookingUrl) ? s.bookingUrl : undefined;
  const address = [s.practiceAddress, [s.practiceZipcode, s.practiceCity].filter(Boolean).join(" ")].filter(Boolean).join(", ");

  let distance: React.ReactNode = unknown;
  const pLat = parseFloat(s.practiceLatitude);
  const pLng = parseFloat(s.practiceLongitude);
  if (data.homeLat !== null && data.homeLng !== null && !isNaN(pLat) && !isNaN(pLng)) {
    distance = formatDistanceKm(haversineKm(data.homeLat, data.homeLng, pLat, pLng), locale);
  } else if (data.homeLat === null) {
    distance = (
      <span className="text-muted-foreground">
        {t("appointments.slot.noHome")}{" "}
        <Link href={`/f/${familyId}/settings#home-address`} className="text-primary hover:underline">{t("appointments.slot.setHome")}</Link>
      </span>
    );
  }

  const insurance =
    data.insuranceSector === "public"
      ? t("appointments.form.insuranceSectorPublic")
      : data.insuranceSector === "private"
        ? t("appointments.form.insuranceSectorPrivate")
        : unknown;

  function onIgnore() {
    start(async () => {
      const res = await ignoreResultAction(familyId, s.resultId);
      if (!res.ok) return void toast.error(res.message);
      toast.success(t("appointments.slot.ignored"));
      router.push(searchHref);
    });
  }

  const rows: { label: string; value: React.ReactNode }[] = [
    { label: t("appointments.slot.subtitle"), value: s.doctorSubtitle || unknown },
    { label: t("appointments.slot.speciality"), value: s.speciality || unknown },
    { label: t("appointments.slot.practice"), value: s.practiceName || unknown },
    { label: t("appointments.slot.motive"), value: s.motiveLabel || unknown },
    { label: t("appointments.slot.insurance"), value: insurance },
    { label: t("appointments.slot.address"), value: address || unknown },
    { label: t("appointments.slot.distance"), value: distance },
  ];

  return (
    <Card>
      <CardHeader className="gap-2 p-4 sm:p-6">
        <CardTitle className="text-xl">{s.doctorName}</CardTitle>
        <p className="font-medium text-primary" suppressHydrationWarning>{formatSlot(s.slot, locale, "full")}</p>
        <div className="flex flex-wrap gap-2">
          <Pill className="bg-muted text-muted-foreground">
            {s.isNextSlot ? t("appointments.slot.nextSlotBadge") : t("appointments.slot.concreteBadge")}
          </Pill>
          <Pill className="bg-primary/10 text-primary">{s.source === "jameda" ? "jameda" : "Doctolib"}</Pill>
        </div>
      </CardHeader>
      <CardContent className="space-y-5 p-4 pt-0 sm:px-6 sm:pb-6">
        <dl className="grid grid-cols-1 gap-x-4 gap-y-1 text-sm sm:grid-cols-[auto_1fr] sm:gap-y-2">
          {rows.map((r) => (
            <div key={r.label} className="contents">
              <dt className="mt-2 text-muted-foreground sm:mt-0">{r.label}</dt>
              <dd className="min-w-0 break-words">{r.value}</dd>
            </div>
          ))}
        </dl>
        <div className="flex flex-col gap-2 sm:flex-row">
          {bookingUrl && (
            <Button asChild className="w-full sm:w-auto">
              <a href={bookingUrl} target="_blank" rel="noopener noreferrer">
                <ExternalLink className="size-4" /> {t("appointments.slot.book")}
              </a>
            </Button>
          )}
          <Button asChild variant="outline" className="w-full sm:w-auto">
            <a href={googleSearchUrl([s.doctorName, s.doctorSubtitle, address])} target="_blank" rel="noopener noreferrer">
              <SearchIcon className="size-4" /> {t("appointments.slot.google")}
            </a>
          </Button>
          {canEdit && (
            <Button variant="ghost" className="w-full sm:w-auto" onClick={onIgnore} disabled={pending} title={t("appointments.slot.ignoreHint")}>
              <EyeOff className="size-4" /> {t("appointments.slot.ignore")}
            </Button>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
