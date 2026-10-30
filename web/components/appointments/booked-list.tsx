"use client";

// "Booked appointments" on the appointments page (phase 7): the slots marked as booked from
// today on, with a link to their search and Remove (only from Ohana, not from the practice).

import { useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { CalendarCheck, ExternalLink, MapPin, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import type { PublicEvent } from "@/lib/calendar/events";
import { removeBookingAction } from "@/app/actions/appointments";
import { formatBooking } from "./book-dialog";

export function BookedList({ familyId, events, canEdit }: { familyId: string; events: PublicEvent[]; canEdit: boolean }) {
  const { t, locale } = useT();
  const router = useRouter();
  const [pending, start] = useTransition();
  if (!events.length) return null;

  function remove(id: string) {
    if (!window.confirm(t("appointments.booking.removeConfirm"))) return;
    start(async () => {
      const res = await removeBookingAction(familyId, id);
      if (!res.ok) return void toast.error(res.message);
      toast.success(t("appointments.booking.removed"));
      router.refresh();
    });
  }

  return (
    <Card className="mb-4">
      <CardHeader className="p-4 pb-2 sm:px-6">
        <CardTitle className="flex items-center gap-2 text-lg">
          <CalendarCheck className="size-5 text-primary" /> {t("appointments.booked.title")}
        </CardTitle>
        <CardDescription>{t("appointments.booked.hint")}</CardDescription>
      </CardHeader>
      <CardContent className="p-4 pt-0 sm:px-6">
        <ul className="divide-y">
          {events.map((e) => (
            <li key={e.id} className="flex items-start gap-2 py-2.5">
              <div className="min-w-0 flex-1 text-sm">
                <p className="font-medium text-primary">{formatBooking({ date: e.date, start: e.start }, locale)}</p>
                <p className="truncate font-medium">
                  {e.searchId ? (
                    <Link href={`/f/${familyId}/appointments/${e.searchId}`} className="hover:underline">
                      {e.title}
                    </Link>
                  ) : (
                    e.title
                  )}
                  {e.person && <span className="font-normal text-muted-foreground"> · {e.person}</span>}
                </p>
                {e.location && (
                  <p className="flex items-center gap-1 truncate text-xs text-muted-foreground">
                    <MapPin className="size-3 shrink-0" /> <span className="truncate">{e.location}</span>
                  </p>
                )}
              </div>
              {e.url && (
                <Button asChild variant="ghost" size="icon" aria-label={t("appointments.slot.book")}>
                  <a href={e.url} target="_blank" rel="noopener noreferrer">
                    <ExternalLink className="size-4" />
                  </a>
                </Button>
              )}
              {canEdit && (
                <Button
                  variant="ghost"
                  size="icon"
                  disabled={pending}
                  aria-label={t("appointments.booking.remove")}
                  title={t("appointments.booking.remove")}
                  onClick={() => remove(e.id)}
                >
                  <Trash2 className="size-4" />
                </Button>
              )}
            </li>
          ))}
        </ul>
      </CardContent>
    </Card>
  );
}
