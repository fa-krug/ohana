"use client";

// "Mark as booked" on the slot page (phase 7): after booking the slot on Doctolib / jameda, an
// editor records it here; it becomes a timed event in the calendar. The date and time start
// as the slot's (in this device's time zone) and can be changed, e.g. when the practice gave
// another time on the phone.

import { useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { CalendarCheck, CalendarDays, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import { bookSlotAction, removeBookingAction } from "@/app/actions/appointments";

export interface BookingInfo {
  eventId: string;
  date: string;
  start: string | null;
  person: string;
}

const pad = (n: number) => String(n).padStart(2, "0");

/** The slot's local day and time ("YYYY-MM-DD", "HH:MM") on this device. */
function localParts(iso: string): { date: string; time: string } {
  const d = new Date(iso);
  return {
    date: `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`,
    time: `${pad(d.getHours())}:${pad(d.getMinutes())}`,
  };
}

export function formatBooking(b: { date: string; start: string | null }, locale: string): string {
  const day = new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", {
    weekday: "short",
    day: "numeric",
    month: "short",
    year: "numeric",
    timeZone: "UTC",
  }).format(new Date(`${b.date}T00:00:00Z`));
  return b.start ? `${day}, ${b.start}` : day;
}

/** The slot's booking state and the button / dialog to mark it as booked. */
export function BookSlot({
  familyId,
  searchId,
  resultId,
  slot,
  searchEnabled,
  booking,
  canEdit,
}: {
  familyId: string;
  searchId: string;
  resultId: number;
  slot: string;
  searchEnabled: boolean;
  booking: BookingInfo | null;
  canEdit: boolean;
}) {
  const { t, locale } = useT();
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [pending, start] = useTransition();
  const initial = localParts(slot);
  const [date, setDate] = useState(initial.date);
  const [time, setTime] = useState(initial.time);
  const [end, setEnd] = useState("");
  const [person, setPerson] = useState("");
  const [note, setNote] = useState("");
  const [stop, setStop] = useState(searchEnabled);

  if (booking) {
    return (
      <div className="flex flex-col gap-2 rounded-lg border border-ok/40 bg-ok/10 p-3 text-sm sm:flex-row sm:items-center">
        <CalendarCheck className="size-4 shrink-0 text-ok max-sm:hidden" />
        <p className="min-w-0 flex-1">
          <span className="font-medium">{t("appointments.booking.bookedFor", { when: formatBooking(booking, locale) })}</span>
          {booking.person && <span className="text-muted-foreground"> · {booking.person}</span>}
        </p>
        <div className="flex gap-2">
          <Button asChild variant="outline" size="sm">
            <Link href={`/f/${familyId}/calendar`}>
              <CalendarDays className="size-4" /> {t("appointments.booking.inCalendar")}
            </Link>
          </Button>
          {canEdit && (
            <Button
              variant="ghost"
              size="sm"
              disabled={pending}
              onClick={() => {
                if (!window.confirm(t("appointments.booking.removeConfirm"))) return;
                start(async () => {
                  const res = await removeBookingAction(familyId, booking.eventId);
                  if (!res.ok) return void toast.error(res.message);
                  toast.success(t("appointments.booking.removed"));
                  router.refresh();
                });
              }}
            >
              <Trash2 className="size-4" /> {t("appointments.booking.remove")}
            </Button>
          )}
        </div>
      </div>
    );
  }
  if (!canEdit) return null;

  function submit(e: React.FormEvent) {
    e.preventDefault();
    start(async () => {
      const res = await bookSlotAction(familyId, searchId, resultId, {
        date,
        start: time,
        end: end || null,
        person,
        note,
        stopSearch: searchEnabled && stop,
      });
      if (!res.ok) return void toast.error(res.message);
      toast.success(t("appointments.booking.saved"));
      setOpen(false);
      router.refresh();
    });
  }

  return (
    <>
      <Button variant="secondary" className="w-full sm:w-auto" onClick={() => setOpen(true)}>
        <CalendarCheck className="size-4" /> {t("appointments.booking.mark")}
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="max-sm:max-w-[calc(100%-2rem)]">
          <DialogHeader>
            <DialogTitle>{t("appointments.booking.title")}</DialogTitle>
            <DialogDescription>{t("appointments.booking.hint")}</DialogDescription>
          </DialogHeader>
          <form onSubmit={submit} className="space-y-4">
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
              <div className="col-span-2 space-y-1.5 sm:col-span-1">
                <Label htmlFor="book-date">{t("appointments.booking.date")}</Label>
                <Input id="book-date" type="date" required value={date} onChange={(e) => setDate(e.target.value)} />
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="book-start">{t("appointments.booking.start")}</Label>
                <Input id="book-start" type="time" required value={time} onChange={(e) => setTime(e.target.value)} />
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="book-end">{t("appointments.booking.end")}</Label>
                <Input id="book-end" type="time" value={end} onChange={(e) => setEnd(e.target.value)} />
              </div>
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="book-person">{t("appointments.booking.person")}</Label>
              <Input
                id="book-person"
                maxLength={80}
                placeholder={t("appointments.booking.personPlaceholder")}
                value={person}
                onChange={(e) => setPerson(e.target.value)}
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="book-note">{t("appointments.booking.note")}</Label>
              <Textarea id="book-note" rows={2} maxLength={1000} value={note} onChange={(e) => setNote(e.target.value)} />
            </div>
            {searchEnabled && (
              <label className="flex items-start gap-2 text-sm">
                <Checkbox className="mt-0.5" checked={stop} onCheckedChange={(v) => setStop(v === true)} />
                <span>
                  {t("appointments.booking.stop")}
                  <span className="block text-xs text-muted-foreground">{t("appointments.booking.stopHint")}</span>
                </span>
              </label>
            )}
            <DialogFooter className="gap-2">
              <Button type="button" variant="outline" onClick={() => setOpen(false)}>
                {t("common.cancel")}
              </Button>
              <Button type="submit" disabled={pending}>
                {t("appointments.booking.save")}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </>
  );
}
