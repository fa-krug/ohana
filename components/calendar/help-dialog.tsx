"use client";

import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { useT } from "@/lib/i18n/provider";
import { useMedia } from "./context";

// [what, does, shown for]: touch gestures or mouse + keyboard, whichever this device has.
const ROWS: [string, string, "touch" | "mouse" | "both"][] = [
  ["tap", "tapDo", "touch"],
  ["longPress", "longPressDo", "touch"],
  ["range", "rangeDo", "touch"],
  ["multi", "multiDo", "touch"],
  ["undoTouch", "undoDo", "touch"],
  ["click", "clickDo", "mouse"],
  ["shift", "shiftDo", "mouse"],
  ["ctrl", "ctrlDo", "mouse"],
  ["type", "typeDo", "both"],
  ["del", "delDo", "mouse"],
  ["copy", "copyDo", "mouse"],
  ["handle", "handleDo", "both"],
  ["arrows", "arrowsDo", "mouse"],
  ["undo", "undoDo", "mouse"],
  ["note", "noteDo", "mouse"],
  ["zoom", "zoomDo", "mouse"],
  ["pages", "pagesDo", "mouse"],
  ["gap", "gapDo", "mouse"],
  ["question", "helpDo", "mouse"],
  ["esc", "escDo", "mouse"],
];

/** How the calendar works: gestures and keyboard shortcuts. */
export function HelpDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) {
  const { t } = useT();
  const touch = useMedia("(hover: none) and (pointer: coarse)");
  const rows = ROWS.filter(([, , on]) => on === "both" || (on === "touch") === touch);
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[calc(100dvh-3rem)] overflow-y-auto sm:max-w-[560px]">
        <DialogHeader>
          <DialogTitle>{t("calendar.help.title")}</DialogTitle>
        </DialogHeader>
        <table className="w-full border-collapse text-sm">
          <tbody>
            {rows.map(([what, does]) => (
              <tr key={does + what} className="border-b last:border-0">
                {/* Our own strings, with <kbd> markup. */}
                <td
                  className="py-2 pr-2.5 align-top font-medium whitespace-nowrap"
                  dangerouslySetInnerHTML={{ __html: t(`calendar.help.${what}`) }}
                />
                <td
                  className="py-2 text-muted-foreground"
                  dangerouslySetInnerHTML={{ __html: t(`calendar.help.${does}`) }}
                />
              </tr>
            ))}
          </tbody>
        </table>
      </DialogContent>
    </Dialog>
  );
}
