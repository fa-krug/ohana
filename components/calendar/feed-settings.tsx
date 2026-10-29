"use client";

// Settings → Calendar feed: the subscription URL (the one thing that works without signing in)
// with its options, and, for editors, a new feed address and the removal of a legacy link.
// Ported from family-planner's settings/SharingSection.tsx.

import { useState } from "react";
import { CalendarPlus, Copy, RefreshCw, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { toast } from "@/components/ui/sonner";
import { copyText } from "@/lib/clipboard";
import { useT } from "@/lib/i18n/provider";
import { calendarUrl } from "./api";
import { usePlanner } from "./context";

export function FeedSettings({ appUrl }: { appUrl: string }) {
  const { t } = useT();
  const store = usePlanner();
  const family = store.family;
  if (!family) return null;
  const edit = !store.readOnly;

  async function rotate(link: "feed" | "legacy", message: string) {
    if (!window.confirm(message)) return;
    try {
      await store.rotateLink(link);
      toast.success(link === "legacy" ? t("calendar.feed.legacyRemoved") : t("calendar.feed.rotated"));
    } catch (err) {
      toast.error(t("calendar.feed.rotateFailed", { msg: (err as Error).message }));
    }
  }

  return (
    <div className="space-y-6">
      <FeedCard
        appUrl={appUrl}
        feedId={family.feedId}
        rotate={edit ? () => rotate("feed", t("calendar.feed.rotateConfirm")) : undefined}
      />
      {edit && family.legacyId && (
        <Card>
          <CardHeader>
            <CardTitle className="text-lg">{t("calendar.feed.legacy")}</CardTitle>
            <CardDescription>{t("calendar.feed.legacyHelp")}</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <UrlField value={calendarUrl(appUrl, family.legacyId)} label={t("calendar.feed.legacy")} />
            <Button variant="outline" size="sm" onClick={() => rotate("legacy", t("calendar.feed.legacyConfirm"))}>
              <Trash2 /> {t("calendar.feed.legacyRemove")}
            </Button>
          </CardContent>
        </Card>
      )}
    </div>
  );
}

function UrlField({ value, label }: { value: string; label: string }) {
  const { t } = useT();
  return (
    <div className="flex gap-2">
      <Input
        readOnly
        value={value}
        aria-label={label}
        className="font-mono text-xs md:text-xs"
        onFocus={(e) => e.target.select()}
      />
      <Button variant="outline" onClick={() => copyText(value, t("common.copied"))}>
        <Copy /> <span className="max-sm:sr-only">{t("common.copy")}</span>
      </Button>
    </div>
  );
}

function FeedCard({ appUrl, feedId, rotate }: { appUrl: string; feedId: string; rotate?: () => void }) {
  const { t, locale } = useT();
  const store = usePlanner();
  const types = store.types;
  const [excluded, setExcluded] = useState<Set<string>>(new Set());
  // Gap warnings are on by default when the year has a type that needs cover.
  const [gapsChoice, setGaps] = useState<boolean | null>(null);
  const gaps = gapsChoice ?? types.some((x) => x.role === "needs_cover");
  const [notes, setNotes] = useState(true);

  const params: Record<string, string> = {};
  const included = types.filter((x) => !excluded.has(x.id));
  if (included.length !== types.length) params.types = included.map((x) => x.id).join(",");
  if (gaps) params.gaps = "1";
  if (notes) params.notes = "1";
  if (locale !== "en") params.lang = locale;
  const url = calendarUrl(appUrl, feedId, params);

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-lg">{t("calendar.feed.title")}</CardTitle>
        <CardDescription>
          {t("calendar.feed.icloudHelp")} {t("calendar.feed.help")}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        <fieldset className="rounded-lg border px-4 pt-2 pb-3">
          <legend className="px-1.5 text-xs font-semibold text-muted-foreground">{t("calendar.feed.include")}</legend>
          {types.length > 0 && (
            <div className="mb-2 flex flex-wrap gap-x-4 gap-y-1.5">
              {types.map((type) => (
                <label key={type.id} className="inline-flex items-center gap-2 text-sm">
                  <Checkbox
                    checked={!excluded.has(type.id)}
                    onCheckedChange={(on) => {
                      const next = new Set(excluded);
                      if (on) next.delete(type.id);
                      else next.add(type.id);
                      setExcluded(next);
                    }}
                  />
                  <span className="size-3 rounded-sm" style={{ backgroundColor: type.color }} aria-hidden />
                  {type.name}
                </label>
              ))}
            </div>
          )}
          <label className="flex items-center gap-2 text-sm">
            <Checkbox checked={gaps} onCheckedChange={(v) => setGaps(!!v)} /> {t("calendar.feed.gaps")}
          </label>
          <label className="mt-1.5 flex items-center gap-2 text-sm">
            <Checkbox checked={notes} onCheckedChange={(v) => setNotes(!!v)} /> {t("calendar.feed.notes")}
          </label>
        </fieldset>
        <UrlField value={url} label={t("calendar.feed.url")} />
        <div className="flex flex-wrap gap-2">
          <Button asChild>
            <a href={url.replace(/^https?:/, "webcal:")}>
              <CalendarPlus /> {t("calendar.feed.subscribe")}
            </a>
          </Button>
          {rotate && (
            <Button variant="outline" onClick={rotate}>
              <RefreshCw /> {t("calendar.feed.rotate")}
            </Button>
          )}
        </div>
        <details className="text-sm">
          <summary className="cursor-pointer font-semibold text-primary">{t("calendar.feed.howto")}</summary>
          <ol className="mt-2 list-decimal space-y-1.5 pl-5 text-muted-foreground [&_b]:text-foreground">
            {/* Our own strings, with <b>/<i> markup. */}
            <li dangerouslySetInnerHTML={{ __html: t("calendar.feed.howtoIos") }} />
            <li dangerouslySetInnerHTML={{ __html: t("calendar.feed.howtoMac") }} />
            <li dangerouslySetInnerHTML={{ __html: t("calendar.feed.howtoSync") }} />
          </ol>
        </details>
      </CardContent>
    </Card>
  );
}
