"use client";

import Link from "next/link";
import { Pencil } from "lucide-react";
import { Button } from "@/components/ui/button";
import { stats } from "@/lib/calendar/core";
import { useT } from "@/lib/i18n/provider";
import { cn } from "@/lib/utils";
import { usePlanner } from "./context";

/** The year's entry types as toggle chips (1–9 on the keyboard), with their workday counts.
 *  A year without types offers to copy them from the closest year that has some. */
export function TypeChips({ className }: { className?: string }) {
  const { t } = useT();
  const store = usePlanner();
  const { types, readOnly, year } = store;
  const settings = `/f/${store.familyId}/settings?tab=calendar&y=${year}`;

  if (!types.length) {
    if (store.typeYears === null) return <div className={cn("min-h-[34px]", className)} />;
    const source = store.copySource();
    return (
      <div className={cn("flex min-h-[34px] flex-wrap items-center gap-2.5 text-sm text-muted-foreground", className)}>
        <span>{readOnly ? t("calendar.types.emptyReadonly", { year }) : t("calendar.types.empty", { year })}</span>
        {!readOnly && source !== null && (
          <Button
            size="sm"
            title={t("calendar.types.copyFromTitle", { from: source, to: year })}
            onClick={() => store.copyTypes(source)}
          >
            {t("calendar.types.copyFrom", { year: source })}
          </Button>
        )}
        {!readOnly && source === null && (
          <Button size="sm" asChild>
            <Link href={settings}>{t("calendar.types.addFirst")}</Link>
          </Button>
        )}
      </div>
    );
  }

  const days = store.selectedDays();
  const s = stats(store.entries, types, year);
  return (
    <div
      className={cn("flex min-w-0 items-center gap-1.5", className)}
      role="toolbar"
      aria-label={t("calendar.toolbar.label")}
    >
      {types.map((type, i) => {
        const st = s.get(type.id)!;
        const active = days.length > 0 && days.every((d) => (store.entries.get(d) ?? []).includes(type.id));
        const title =
          t("calendar.chip.title", {
            name: type.name,
            role: t(`calendar.role.${type.role}`),
            days: t("calendar.count.days", { count: st.days }),
            workdays: t("calendar.count.workdays", { count: st.workdays }),
            year,
          }) + (readOnly || i > 8 ? "" : t("calendar.chip.toggleHint", { key: i + 1 }));
        return (
          <button
            key={type.id}
            type="button"
            className={cn("chip", active && "active")}
            style={{ "--c": type.color } as React.CSSProperties}
            disabled={readOnly}
            title={title}
            aria-pressed={active}
            onClick={() => store.toggleOnSelection(type.id)}
          >
            <span
              className={cn("swatch", type.role === "needs_cover" && "needs")}
              style={{ backgroundColor: type.color }}
            />
            <span className="name">{type.name}</span>
            <span className="count">{t("calendar.chip.count", { n: st.workdays })}</span>
          </button>
        );
      })}
      {!readOnly && (
        <Button
          variant="outline"
          size="icon"
          className="size-[34px] shrink-0 rounded-full"
          title={t("calendar.toolbar.editTypes")}
          aria-label={t("calendar.toolbar.editTypes")}
          asChild
        >
          <Link href={settings}>
            <Pencil />
          </Link>
        </Button>
      )}
    </div>
  );
}
