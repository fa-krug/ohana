"use client";

// Settings → Household (phase 7): which events go to the family's notification channels, and
// to which. Appointment searches pick their channels themselves, so that event only has a switch.

import { useState, useTransition } from "react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import { Switch } from "@/components/ui/switch";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import { EVENT_HAS_CHANNELS, type EventPref } from "@/lib/notifications/prefs-shared";
import { setNotificationPrefAction } from "@/app/actions/notifications";

interface ChannelOption {
  id: string;
  name: string;
  enabled: boolean;
}

export function NotificationEventsCard({
  familyId,
  prefs,
  channels,
}: {
  familyId: string;
  prefs: EventPref[];
  channels: ChannelOption[];
}) {
  const { t } = useT();
  return (
    <Card id="notification-events" className="scroll-mt-20">
      <CardHeader>
        <CardTitle className="text-lg">{t("notifications.events.title")}</CardTitle>
        <CardDescription>{t("notifications.events.hint")}</CardDescription>
      </CardHeader>
      <CardContent>
        <ul className="divide-y rounded-md border">
          {prefs.map((p) => (
            <EventRow key={p.event} familyId={familyId} pref={p} channels={channels} />
          ))}
        </ul>
      </CardContent>
    </Card>
  );
}

function EventRow({ familyId, pref, channels }: { familyId: string; pref: EventPref; channels: ChannelOption[] }) {
  const { t } = useT();
  const [state, setState] = useState(pref);
  const [pending, start] = useTransition();
  const withChannels = EVENT_HAS_CHANNELS[pref.event];

  function save(next: EventPref) {
    const before = state;
    setState(next);
    start(async () => {
      const res = await setNotificationPrefAction(familyId, next);
      if (!res.ok) {
        setState(before);
        return void toast.error(res.message);
      }
      toast.success(t("notifications.events.saved"));
    });
  }

  const all = state.channelIds === null;
  const chosen = new Set(state.channelIds ?? []);
  const toggle = (id: string, on: boolean) => {
    const ids = new Set(chosen);
    if (on) ids.add(id);
    else ids.delete(id);
    save({ ...state, channelIds: [...ids] });
  };

  return (
    <li className="space-y-2 p-3">
      <label className="flex items-start justify-between gap-4">
        <span className="min-w-0">
          <span className="block text-sm font-medium">{t(`notifications.events.${pref.event}`)}</span>
          <span className="block text-xs text-muted-foreground">{t(`notifications.events.${pref.event}Hint`)}</span>
        </span>
        <Switch
          checked={state.enabled}
          disabled={pending}
          aria-label={t(`notifications.events.${pref.event}`)}
          onCheckedChange={(enabled) => save({ ...state, enabled })}
        />
      </label>
      {withChannels && state.enabled && (
        channels.length === 0 ? (
          <p className="text-xs text-muted-foreground">{t("notifications.events.noChannels")}</p>
        ) : (
          <div className="flex flex-wrap items-center gap-x-4 gap-y-1.5 text-sm">
            <span className="text-xs text-muted-foreground">{t("notifications.events.channelsLabel")}:</span>
            <label className="inline-flex items-center gap-2">
              <Checkbox
                checked={all}
                disabled={pending}
                onCheckedChange={(v) => save({ ...state, channelIds: v === true ? null : channels.map((c) => c.id) })}
              />
              {t("notifications.events.allChannels")}
            </label>
            {!all &&
              channels.map((c) => (
                <label key={c.id} className="inline-flex items-center gap-2">
                  <Checkbox checked={chosen.has(c.id)} disabled={pending} onCheckedChange={(v) => toggle(c.id, v === true)} />
                  <span className={c.enabled ? "" : "text-muted-foreground"}>{c.name}</span>
                </label>
              ))}
          </div>
        )
      )}
    </li>
  );
}
