"use client";

import { useState, type ReactNode } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ExternalLink } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { NativeSelect } from "@/components/ui/native-select";
import { Switch } from "@/components/ui/switch";
import { toast } from "@/components/ui/sonner";
import { AsyncCombobox } from "@/components/async-combobox";
import { useT } from "@/lib/i18n/provider";
import type { SearchListItem } from "@/lib/appointments/serialize";
import { citySlug } from "@/lib/appointments/jameda/city";
import { createSearchAction, updateSearchAction } from "@/app/actions/appointments";

function doctolibPreviewUrl(slug: string, lat: string, lng: string, sector: string): string | null {
  if (!slug || !lat || !lng) return null;
  const params = new URLSearchParams({ around_me: "true", keyword: slug, latitude: lat, longitude: lng });
  if (sector) params.set("insuranceSector", sector);
  return `https://www.doctolib.de/search?${params}`;
}

function jamedaPreviewUrl(
  slug: string,
  label: string,
  type: string,
  locationLabel: string,
  insuranceType: string,
  kidsFriendly: boolean,
  video: string,
): string | null {
  const loc = (locationLabel.split(",")[0] ?? "").trim();
  if (!loc) return null;
  const extra = new URLSearchParams();
  if (insuranceType) extra.append("filters[insurance_types][]", insuranceType);
  if (kidsFriendly) extra.append("filters[kids_friendly][]", "true");
  if (video === "only") extra.append("filters[online_only][]", "true");
  if (type === "specialization" && slug) {
    const city = citySlug(locationLabel);
    if (!city) return null;
    const qs = extra.toString();
    return `https://www.jameda.de/${slug}/${city}${qs ? `?${qs}` : ""}`;
  }
  if (!label) return null;
  const params = new URLSearchParams();
  params.set("q", label);
  params.set("loc", loc);
  for (const [k, v] of extra) params.append(k, v);
  return `https://www.jameda.de/suchen?${params.toString()}`;
}

interface ChannelOption {
  id: string;
  name: string;
  provider: string;
  enabled: boolean;
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="space-y-3 rounded-lg border bg-card p-4">
      <h2 className="text-sm font-semibold">{title}</h2>
      {children}
    </section>
  );
}

function PreviewLink({ href, label }: { href: string; label: string }) {
  return (
    <a href={href} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 text-xs text-primary underline-offset-2 hover:underline">
      <ExternalLink className="size-3" /> {label}
    </a>
  );
}

function Toggle({ label, checked, onChange, strong }: { label: string; checked: boolean; onChange: (v: boolean) => void; strong?: boolean }) {
  return (
    <label className={`flex cursor-pointer items-center justify-between gap-3 text-sm ${strong ? "font-medium" : ""}`}>
      <span>{label}</span>
      <Switch checked={checked} onCheckedChange={onChange} />
    </label>
  );
}

export function SearchForm({ familyId, search, channels }: { familyId: string; search?: SearchListItem; channels: ChannelOption[] }) {
  const { t } = useT();
  const router = useRouter();
  const api = `/api/v1/families/${familyId}`;
  const initialSources = search?.sources ?? "doctolib";
  const [name, setName] = useState(search?.name ?? "");
  // Sources are two independent switches; the stored `sources` string is derived on save.
  const [doctolibOn, setDoctolibOn] = useState(initialSources === "doctolib" || initialSources === "both");
  const [jamedaOn, setJamedaOn] = useState(initialSources === "jameda" || initialSources === "both");
  const [specialitySlug, setSpecialitySlug] = useState(search?.specialitySlug ?? "");
  const [specialityLabel, setSpecialityLabel] = useState(search?.specialityLabel ?? "");
  const [jamedaSpecialitySlug, setJamedaSpecialitySlug] = useState(search?.jamedaSpecialitySlug ?? "");
  const [jamedaSpecialityLabel, setJamedaSpecialityLabel] = useState(search?.jamedaSpecialityLabel ?? "");
  const [jamedaSpecialityType, setJamedaSpecialityType] = useState(search?.jamedaSpecialityType ?? "leistung");
  const [jamedaInsuranceType, setJamedaInsuranceType] = useState(search?.jamedaInsuranceType ?? "");
  const [jamedaKidsFriendly, setJamedaKidsFriendly] = useState(search?.jamedaKidsFriendly ?? false);
  const [jamedaVideo, setJamedaVideo] = useState(search?.jamedaVideo ?? "any");
  const [latitude, setLatitude] = useState(search?.latitude ?? "");
  const [longitude, setLongitude] = useState(search?.longitude ?? "");
  const [locationLabel, setLocationLabel] = useState(search?.locationLabel ?? "");
  const [insuranceSector, setInsuranceSector] = useState(search?.insuranceSector ?? "");
  const [dayLimit, setDayLimit] = useState(String(search?.dayLimit ?? 14));
  const [maxPages, setMaxPages] = useState(String(search?.maxPages ?? 3));
  const [enabled, setEnabled] = useState(search?.enabled ?? true);
  const [scheduleType, setScheduleType] = useState(search?.scheduleType ?? "MINUTES");
  const [scheduleMinutes, setScheduleMinutes] = useState(String(search?.scheduleMinutes ?? 30));
  const [cron, setCron] = useState(search?.cron ?? "");
  const [notifyOnlyEarlier, setNotifyOnlyEarlier] = useState(search?.notifyOnlyEarlier ?? false);
  const [channelIds, setChannelIds] = useState<string[]>(search?.channelIds ?? (channels.length === 1 ? [channels[0].id] : []));
  const [busy, setBusy] = useState(false);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    const sources = doctolibOn && jamedaOn ? "both" : doctolibOn ? "doctolib" : jamedaOn ? "jameda" : "none";
    const input = {
      name, sources, specialitySlug, specialityLabel,
      jamedaSpecialitySlug, jamedaSpecialityLabel, jamedaSpecialityType,
      jamedaInsuranceType, jamedaKidsFriendly, jamedaVideo,
      latitude, longitude, locationLabel, insuranceSector,
      dayLimit: Number(dayLimit),
      maxPages: Number(maxPages),
      enabled, scheduleType,
      scheduleMinutes: scheduleType === "MINUTES" ? Number(scheduleMinutes) : null,
      cron, notifyOnlyEarlier, channelIds,
    };
    const res = search ? await updateSearchAction(familyId, search.id, input) : await createSearchAction(familyId, input);
    setBusy(false);
    if (!res.ok) return void toast.error(res.message || t("appointments.form.couldNotSave"));
    toast.success(search ? t("appointments.form.saved") : t("appointments.form.created"));
    const id = search ? search.id : (res.data as { id: string }).id;
    router.push(`/f/${familyId}/appointments/${id}`);
    router.refresh();
  }

  const doctolibPreview = doctolibPreviewUrl(specialitySlug, latitude, longitude, insuranceSector);
  const jamedaPreview = jamedaPreviewUrl(
    jamedaSpecialitySlug, jamedaSpecialityLabel, jamedaSpecialityType,
    locationLabel, jamedaInsuranceType, jamedaKidsFriendly, jamedaVideo,
  );
  const termType = (type: string) =>
    type === "specialization"
      ? t("appointments.form.jamedaTypeSpecialization")
      : type === "erkrankung"
        ? t("appointments.form.jamedaTypeErkrankung")
        : t("appointments.form.jamedaTypeLeistung");

  return (
    <form onSubmit={save} className="min-w-0 space-y-4">
      <Section title={t("appointments.form.sectionGeneral")}>
        <div className="space-y-2">
          <Label htmlFor="search-name">{t("appointments.form.name")}</Label>
          <Input id="search-name" value={name} maxLength={200} onChange={(e) => setName(e.target.value)} placeholder={t("appointments.form.namePlaceholder")} />
        </div>
        <Toggle label={t("appointments.form.enabled")} checked={enabled} onChange={setEnabled} />
        <Toggle label={t("appointments.form.notifyOnlyEarlier")} checked={notifyOnlyEarlier} onChange={setNotifyOnlyEarlier} />
      </Section>

      <Section title={t("appointments.form.sectionLocation")}>
        <AsyncCombobox<{ label: string; latitude: string; longitude: string }>
          endpoint={`${api}/geocode`}
          getLabel={(i) => i.label}
          initialLabel={locationLabel || (latitude && `${latitude}, ${longitude}`) || ""}
          placeholder={t("appointments.form.locationPlaceholder")}
          onSelect={(i) => { setLatitude(i.latitude); setLongitude(i.longitude); setLocationLabel(i.label); }}
        />
        {latitude && <p className="text-xs text-muted-foreground">{latitude}, {longitude}</p>}
      </Section>

      <Section title={t("appointments.form.sectionSources")}>
        <Toggle strong label="Doctolib" checked={doctolibOn} onChange={setDoctolibOn} />
        {doctolibOn && (
          <div className="space-y-3 rounded-md border bg-muted/30 p-3">
            <div className="space-y-2">
              <Label>{t("appointments.form.speciality")}</Label>
              <AsyncCombobox<{ slug: string; label: string }>
                endpoint={`${api}/appointments/doctolib-specialities`}
                getLabel={(i) => i.label}
                initialLabel={specialityLabel || specialitySlug}
                placeholder={t("appointments.form.specialityPlaceholder")}
                onSelect={(i) => { setSpecialitySlug(i.slug); setSpecialityLabel(i.label); }}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="insurance-sector">{t("appointments.form.insuranceSector")}</Label>
              <NativeSelect id="insurance-sector" value={insuranceSector} onChange={(e) => setInsuranceSector(e.target.value)}>
                <option value="">{t("appointments.form.any")}</option>
                <option value="public">{t("appointments.form.insuranceSectorPublic")}</option>
                <option value="private">{t("appointments.form.insuranceSectorPrivate")}</option>
              </NativeSelect>
            </div>
            {doctolibPreview && <PreviewLink href={doctolibPreview} label={t("appointments.form.previewDoctolib")} />}
          </div>
        )}

        <Toggle strong label="jameda" checked={jamedaOn} onChange={setJamedaOn} />
        {jamedaOn && (
          <div className="space-y-3 rounded-md border bg-muted/30 p-3">
            <div className="space-y-2">
              <Label>{t("appointments.form.jamedaTerm")}</Label>
              <AsyncCombobox<{ slug: string; label: string; type: string }>
                endpoint={`${api}/appointments/jameda-terms`}
                getLabel={(i) => i.label}
                getMeta={(i) => termType(i.type)}
                initialLabel={jamedaSpecialityLabel || jamedaSpecialitySlug}
                placeholder={t("appointments.form.specialityPlaceholder")}
                onSelect={(i) => { setJamedaSpecialitySlug(i.slug); setJamedaSpecialityLabel(i.label); setJamedaSpecialityType(i.type); }}
              />
              {jamedaSpecialitySlug && <p className="text-xs text-muted-foreground">{termType(jamedaSpecialityType)}</p>}
            </div>
            <div className="space-y-2">
              <Label htmlFor="jameda-insurance">{t("appointments.form.insuranceSector")}</Label>
              <NativeSelect id="jameda-insurance" value={jamedaInsuranceType} onChange={(e) => setJamedaInsuranceType(e.target.value)}>
                <option value="">{t("appointments.form.any")}</option>
                <option value="government">{t("appointments.form.insuranceSectorPublic")}</option>
                <option value="private">{t("appointments.form.insuranceSectorPrivate")}</option>
                <option value="public_selfpay">{t("appointments.form.selfPayer")}</option>
              </NativeSelect>
            </div>
            <Toggle label={t("appointments.form.kidsFriendly")} checked={jamedaKidsFriendly} onChange={setJamedaKidsFriendly} />
            <div className="space-y-2">
              <Label htmlFor="jameda-video">{t("appointments.form.video")}</Label>
              <NativeSelect id="jameda-video" value={jamedaVideo} onChange={(e) => setJamedaVideo(e.target.value)}>
                <option value="any">{t("appointments.form.any")}</option>
                <option value="only">{t("appointments.form.videoOnly")}</option>
                <option value="exclude">{t("appointments.form.videoExclude")}</option>
              </NativeSelect>
            </div>
            {jamedaPreview && <PreviewLink href={jamedaPreview} label={t("appointments.form.previewJameda")} />}
          </div>
        )}
      </Section>

      <Section title={t("appointments.form.sectionSchedule")}>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div className="space-y-2">
            <Label htmlFor="schedule-type">{t("appointments.form.rhythm")}</Label>
            <NativeSelect id="schedule-type" value={scheduleType} onChange={(e) => setScheduleType(e.target.value)}>
              <option value="MINUTES">{t("appointments.form.everyNMinutes")}</option>
              <option value="HOURLY">{t("appointments.form.hourly")}</option>
              <option value="DAILY">{t("appointments.form.daily")}</option>
              <option value="CRON">{t("appointments.form.cron")}</option>
            </NativeSelect>
          </div>
          {scheduleType === "MINUTES" && (
            <div className="space-y-2">
              <Label htmlFor="schedule-minutes">{t("appointments.form.intervalMinutes")}</Label>
              <Input id="schedule-minutes" type="number" inputMode="numeric" min={1} max={1440} value={scheduleMinutes} onChange={(e) => setScheduleMinutes(e.target.value)} />
            </div>
          )}
          {scheduleType === "CRON" && (
            <div className="space-y-2">
              <Label htmlFor="schedule-cron">{t("appointments.form.cronLabel")}</Label>
              <Input id="schedule-cron" value={cron} onChange={(e) => setCron(e.target.value)} placeholder="*/15 * * * *" />
            </div>
          )}
          <div className="space-y-2">
            <Label htmlFor="day-limit">{t("appointments.form.dayLimit")}</Label>
            <Input id="day-limit" type="number" inputMode="numeric" min={1} max={365} value={dayLimit} onChange={(e) => setDayLimit(e.target.value)} />
          </div>
          <div className="space-y-2">
            <Label htmlFor="max-pages">{t("appointments.form.maxPages")}</Label>
            <Input id="max-pages" type="number" inputMode="numeric" min={1} max={20} value={maxPages} onChange={(e) => setMaxPages(e.target.value)} />
          </div>
        </div>
      </Section>

      <Section title={t("appointments.form.sectionNotifications")}>
        {channels.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {t("appointments.form.noChannels")}{" "}
            <Link href={`/f/${familyId}/settings#notifications`} className="text-primary hover:underline">{t("appointments.form.addChannel")}</Link>
          </p>
        ) : (
          <>
            <p className="text-xs text-muted-foreground">{t("appointments.form.channelsHint")}</p>
            {channels.map((c) => (
              <Toggle
                key={c.id}
                label={`${c.name} · ${c.provider}${c.enabled ? "" : ` (${t("notifications.channels.disabled")})`}`}
                checked={channelIds.includes(c.id)}
                onChange={(v) => setChannelIds((prev) => (v ? [...prev, c.id] : prev.filter((x) => x !== c.id)))}
              />
            ))}
          </>
        )}
      </Section>

      <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
        <Button type="button" variant="outline" onClick={() => router.back()}>{t("common.cancel")}</Button>
        <Button type="submit" disabled={busy || !name.trim()}>
          {search ? t("common.save") : t("appointments.form.create")}
        </Button>
      </div>
    </form>
  );
}
