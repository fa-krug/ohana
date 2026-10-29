"use client";

// Settings → Calendar: the entry types of a year (add, rename, color, role, order, delete,
// copy from another year) and the per-device view settings. Ported from family-planner's
// settings/VacationSection.tsx.

import { useEffect, useRef, useState } from "react";
import { ArrowDown, ArrowUp, ChevronLeft, ChevronRight, Copy, Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { toast } from "@/components/ui/sonner";
import { type EntryType, type Role, ROLES } from "@/lib/calendar/core";
import { useT } from "@/lib/i18n/provider";
import { usePlanner } from "./context";
import { setAlwaysWeekdays, useViewPrefs } from "./view-prefs";

function rememberYear(y: number) {
  const url = new URL(window.location.href);
  url.searchParams.set("y", String(y));
  window.history.replaceState(window.history.state, "", url);
}

export function CalendarSettings() {
  const { t } = useT();
  const store = usePlanner();
  const prefs = useViewPrefs();
  const [focusId, setFocusId] = useState<string | null>(null);
  const year = store.year;
  const setYear = (y: number) => {
    store.setYear(y);
    rememberYear(store.year);
  };

  async function remove(type: EntryType) {
    const used = store.daysWith(type.id);
    const msg = used
      ? t("calendar.types.confirmDeleteUsed", {
          name: type.name,
          days: t("calendar.count.daysDative", { count: used }),
          year,
        })
      : t("calendar.types.confirmDelete", { name: type.name });
    if (window.confirm(msg)) await store.deleteType(type.id);
  }

  const source = store.copySource();
  const otherYears = (store.typeYears ?? []).filter((y) => y !== year);

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">{t("calendar.types.titleYear", { year })}</CardTitle>
          <CardDescription>{t("calendar.types.yearNote", { year })}</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="flex items-center gap-1">
            <Button variant="ghost" size="icon" aria-label={t("calendar.year.prev")} onClick={() => setYear(year - 1)}>
              <ChevronLeft />
            </Button>
            <span className="w-14 text-center font-semibold tabular-nums">{year}</span>
            <Button variant="ghost" size="icon" aria-label={t("calendar.year.next")} onClick={() => setYear(year + 1)}>
              <ChevronRight />
            </Button>
          </div>
          {store.readOnly && <p className="text-sm text-muted-foreground">{t("calendar.types.readonly")}</p>}
          {store.typeYears !== null && !store.types.length && (
            <p className="text-sm text-muted-foreground">
              {store.readOnly ? t("calendar.types.emptyReadonly", { year }) : t("calendar.types.empty", { year })}
            </p>
          )}
          <div className="space-y-2">
            {store.types.map((type, i) => (
              <TypeRow
                key={type.id}
                type={type}
                first={i === 0}
                last={i === store.types.length - 1}
                autoFocus={type.id === focusId}
                disabled={store.readOnly}
                onChange={(patch) => store.updateType(type.id, patch)}
                onMove={(dir) => store.moveType(i, dir)}
                onDelete={() => remove(type)}
              />
            ))}
          </div>
          {!store.readOnly && (
            <div className="flex flex-wrap gap-2">
              <Button
                variant="outline"
                onClick={async () => {
                  const type = await store.addType();
                  if (type) setFocusId(type.id);
                }}
              >
                <Plus /> {t("calendar.types.add")}
              </Button>
              {!store.types.length && source !== null && (
                <Button
                  title={t("calendar.types.copyFromTitle", { from: source, to: year })}
                  onClick={() => store.copyTypes(source)}
                >
                  {t("calendar.types.copyFrom", { year: source })}
                </Button>
              )}
            </div>
          )}
          {!store.readOnly && otherYears.length > 0 && <CopyFromYear years={otherYears} year={year} />}
          <details className="text-sm">
            <summary className="cursor-pointer font-semibold text-primary">{t("calendar.types.rolesSummary")}</summary>
            <ul className="mt-2 list-disc space-y-1 rounded-lg bg-muted py-2.5 pr-3 pl-7 text-muted-foreground [&_b]:text-foreground">
              {/* Our own strings, with <b> markup. */}
              {["helpNeeds", "helpCovers", "helpDayOff", "helpNone"].map((k) => (
                <li key={k} dangerouslySetInnerHTML={{ __html: t(`calendar.types.${k}`) }} />
              ))}
            </ul>
          </details>
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">{t("calendar.view.title")}</CardTitle>
          <CardDescription>{t("calendar.view.device")}</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <label className="flex items-center justify-between gap-4 text-sm" title={t("calendar.view.weekdaysTitle")}>
            <span>{t("calendar.view.weekdays")}</span>
            <Switch checked={prefs.alwaysWeekdays} onCheckedChange={setAlwaysWeekdays} />
          </label>
          <label
            className="flex items-center justify-between gap-4 text-sm"
            title={t("calendar.view.skipWeekendsTitle")}
          >
            <span>{t("calendar.toolbar.skipWeekends")}</span>
            <Switch checked={prefs.skipWeekends} onCheckedChange={(v) => store.setSkipWeekends(v)} />
          </label>
        </CardContent>
      </Card>
    </div>
  );
}

/** Copies the types of another year into the shown one (the ones it doesn't have yet). */
function CopyFromYear({ years, year }: { years: number[]; year: number }) {
  const { t } = useT();
  const store = usePlanner();
  const [from, setFrom] = useState(years[years.length - 1]);
  useEffect(() => {
    if (!years.includes(from)) setFrom(years[years.length - 1]);
  }, [years, from]);
  return (
    <div className="space-y-1.5 border-t pt-4">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
        <span className="text-sm font-medium">{t("calendar.types.copyOther")}</span>
        <div className="flex gap-2">
          <select
            className="h-9 rounded-md border border-input bg-background pr-9 pl-3 text-sm"
            aria-label={t("calendar.year.label")}
            value={from}
            onChange={(e) => setFrom(Number(e.target.value))}
          >
            {years.map((y) => (
              <option key={y} value={y}>
                {y}
              </option>
            ))}
          </select>
          <Button
            variant="outline"
            size="sm"
            onClick={async () => {
              if (await store.copyTypes(from)) toast.success(t("calendar.types.copied"));
            }}
          >
            <Copy /> {t("common.copy")}
          </Button>
        </div>
      </div>
      <p className="text-xs text-muted-foreground">{t("calendar.types.copyOtherHint", { year })}</p>
    </div>
  );
}

function TypeRow({
  type,
  first,
  last,
  autoFocus,
  disabled,
  onChange,
  onMove,
  onDelete,
}: {
  type: EntryType;
  first: boolean;
  last: boolean;
  autoFocus: boolean;
  disabled: boolean;
  onChange: (patch: Partial<EntryType>) => void;
  onMove: (dir: -1 | 1) => void;
  onDelete: () => void;
}) {
  const { t } = useT();
  const [name, setName] = useState(type.name);
  const nameRef = useRef<HTMLInputElement>(null);
  useEffect(() => setName(type.name), [type.name]);
  useEffect(() => {
    if (autoFocus) nameRef.current?.select();
  }, [autoFocus]);

  return (
    <div className="flex flex-wrap items-center gap-1.5 border-b pb-2 last:border-0 sm:flex-nowrap sm:border-0 sm:pb-0">
      <input
        type="color"
        className="h-10 w-11 shrink-0 cursor-pointer rounded-md border bg-card p-1 disabled:cursor-default"
        title={t("calendar.types.color")}
        aria-label={t("calendar.types.color")}
        value={type.color}
        disabled={disabled}
        onChange={(e) => onChange({ color: e.target.value })}
      />
      <Input
        ref={nameRef}
        className="min-w-0 flex-1 basis-[calc(100%-3.25rem)] sm:basis-auto"
        aria-label={t("calendar.types.name")}
        maxLength={80}
        value={name}
        disabled={disabled}
        onChange={(e) => setName(e.target.value)}
        onBlur={() => {
          const next = name.trim();
          if (!next) setName(type.name);
          else if (next !== type.name) onChange({ name: next });
        }}
        onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()}
      />
      <select
        className="h-10 min-w-0 flex-1 rounded-md border border-input bg-background pr-9 pl-3 text-sm sm:w-44 sm:flex-none"
        aria-label={t("calendar.types.role")}
        value={type.role}
        disabled={disabled}
        onChange={(e) => onChange({ role: e.target.value as Role })}
      >
        {ROLES.map((r) => (
          <option key={r} value={r}>
            {t(`calendar.role.${r}`)}
          </option>
        ))}
      </select>
      {!disabled && (
        <>
          <Button
            variant="ghost"
            size="icon"
            className="size-9"
            title={t("calendar.types.up")}
            aria-label={t("calendar.types.up")}
            disabled={first}
            onClick={() => onMove(-1)}
          >
            <ArrowUp />
          </Button>
          <Button
            variant="ghost"
            size="icon"
            className="size-9"
            title={t("calendar.types.down")}
            aria-label={t("calendar.types.down")}
            disabled={last}
            onClick={() => onMove(1)}
          >
            <ArrowDown />
          </Button>
          <Button
            variant="ghost"
            size="icon"
            className="size-9"
            title={t("calendar.types.delete")}
            aria-label={t("calendar.types.delete")}
            onClick={onDelete}
          >
            <Trash2 />
          </Button>
        </>
      )}
    </div>
  );
}
