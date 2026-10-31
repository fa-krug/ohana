"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { noteOrNull, sameNote } from "@/lib/calendar/core";
import { useT } from "@/lib/i18n/provider";
import { cn } from "@/lib/utils";
import { usePlannerStore } from "./context";
import { fmtDate } from "./grid";

const NOTE_ICONS = [
  "🎄",
  "🎅",
  "🎁",
  "🎆",
  "🐣",
  "🐰",
  "🎃",
  "🎂",
  "🎉",
  "❤️",
  "⭐",
  "📌",
  "✈️",
  "🏖️",
  "⛷️",
  "🏫",
  "🏥",
  "🎓",
  "💼",
  "⚽",
];

/** Icon and/or comment for the days it was opened with. */
export function NoteDialog({ days, onClose }: { days: string[]; onClose: () => void }) {
  const { t, locale } = useT();
  const store = usePlannerStore();
  const notes = days.map((d) => store.notes.get(d) ?? null);
  // Prefill only if every day has the same note; otherwise saving replaces them.
  const same = notes.every((n) => sameNote(n, notes[0]));
  const initial = same ? noteOrNull(notes[0]) : null;
  const [icon, setIcon] = useState(initial?.icon ?? "");
  const [comment, setComment] = useState(initial?.comment ?? "");

  const save = () => {
    const i = icon.trim(),
      c = comment.trim();
    store.commitNotes(new Map(days.map((d) => [d, i || c ? { icon: i, comment: c } : null])));
    onClose();
  };
  const remove = () => {
    store.commitNotes(new Map(days.map((d) => [d, null])));
    onClose();
  };

  const title =
    days.length === 1
      ? fmtDate(locale, days[0], { weekday: "long", day: "numeric", month: "long", year: "numeric" })
      : t("calendar.note.days", {
          days: t("calendar.count.days", { count: days.length }),
          span: `${fmtDate(locale, days[0])} – ${fmtDate(locale, days[days.length - 1])}`,
        });

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent
        className="sm:max-w-[520px]"
        // On touch screens the keyboard would cover the icons, so only focus with a mouse.
        onOpenAutoFocus={(e) => {
          if (!matchMedia("(pointer: fine)").matches) e.preventDefault();
        }}
      >
        <DialogHeader>
          <DialogTitle>{t("calendar.note.title")}</DialogTitle>
          <DialogDescription>{title}</DialogDescription>
        </DialogHeader>
        <div className="grid grid-cols-5 gap-1.5 sm:grid-cols-10" role="group" aria-label={t("calendar.note.icon")}>
          {NOTE_ICONS.map((e) => (
            <button
              key={e}
              type="button"
              aria-pressed={icon === e}
              className={cn(
                "h-10 rounded-md border bg-muted text-xl transition hover:scale-105",
                icon === e && "border-primary bg-primary/15 ring-2 ring-primary/20",
              )}
              // Clicking the picked icon again unpicks it.
              onClick={() => setIcon(icon === e ? "" : e)}
            >
              {e}
            </button>
          ))}
        </div>
        <label className="flex items-center gap-2.5 text-sm font-semibold">
          {t("calendar.note.iconOther")}
          <Input
            className="w-[5.5em] text-center text-lg"
            maxLength={16}
            autoComplete="off"
            value={icon}
            onChange={(e) => setIcon(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.nativeEvent.isComposing) {
                e.preventDefault();
                save();
              }
            }}
          />
        </label>
        <label className="grid gap-1.5 text-sm font-semibold">
          {t("calendar.note.comment")}
          <Textarea
            autoFocus
            rows={3}
            maxLength={500}
            placeholder={t("calendar.note.commentPlaceholder")}
            value={comment}
            onChange={(e) => setComment(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && (e.ctrlKey || e.metaKey) && !e.nativeEvent.isComposing) {
                e.preventDefault();
                save();
              }
            }}
          />
        </label>
        {!same && <p className="text-sm text-muted-foreground">{t("calendar.note.replaceHint")}</p>}
        <DialogFooter className="gap-2 sm:justify-between">
          {notes.some(Boolean) ? (
            <Button variant="outline" onClick={remove}>
              {t("calendar.note.remove")}
            </Button>
          ) : (
            <span />
          )}
          <div className="flex gap-2 max-sm:flex-col-reverse">
            <Button variant="outline" onClick={onClose}>
              {t("calendar.note.cancel")}
            </Button>
            <Button title="Ctrl/⌘ + Enter" onClick={save}>
              {t("calendar.note.save")}
            </Button>
          </div>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
