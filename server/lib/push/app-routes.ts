// The app's push routes (phase 9), part of /api/v1/me (lib/auth/app-routes.ts); the device is
// the request's API token.
//
// GET    /me/push                 → {registered, platform, mutedFamilyIds, lastSentAt, lastError}
// PUT    /me/push {relay, relayToken, key, platform, mutedFamilyIds?}   registers or renews
//        (409 when `relay` isn't this server's PUSH_RELAY_URL; 404 when push is off)
// PATCH  /me/push {mutedFamilyIds}  the families this device doesn't want pushes for
// DELETE /me/push                 stops pushes to this device
// POST   /me/push/test            one push to this device right away (502 when it fails)
// GET    /me/badge?today=         {count, tomorrow: {day, count}}: the app icon's number
//        (lib/chores/badge.ts) and the one from the next midnight on, without the families this
//        device muted; `today` YYYY-MM-DD, default the server's day

import type { AppRoutes } from "@/lib/api/app-router";
import { HttpError } from "@/lib/api/http";
import { isValidDate } from "@/lib/calendar/dates";
import { choreBadges } from "@/lib/chores/badge";
import { pickLocale } from "@/lib/i18n/locale";
import { translator } from "@/lib/notifications/locale";
import { pushToDevices } from "./deliver";
import { deleteDeviceOfToken, deviceDto, deviceOfToken, mutedOf, registerDevice, requireRelay, setMuted } from "./devices";
import type { RelayClient } from "./relay";

export function pushRoutes(opts: { relay?: RelayClient } = {}): AppRoutes {
  return [
    [
      ["push"],
      {
        GET: (c) => deviceDto(deviceOfToken(c.db, c.token.id)),
        PUT: async (c) => deviceDto(registerDevice(c.db, c.user, c.token.id, await c.body(), c.now)),
        PATCH: async (c) => deviceDto(setMuted(c.db, c.token.id, await c.body(), c.now)),
        DELETE: (c) => {
          deleteDeviceOfToken(c.db, c.token.id);
          return deviceDto(undefined);
        },
      },
    ],
    [
      ["push", "test"],
      {
        POST: async (c) => {
          const relayUrl = requireRelay();
          const device = deviceOfToken(c.db, c.token.id);
          if (!device) throw new HttpError(404, "This device doesn't get push notifications.");
          const t = translator(pickLocale([c.user.preferredLanguage]));
          const res = await pushToDevices(
            c.db,
            [device],
            { title: t("notifications.push.test.title"), body: t("notifications.push.test.body") },
            undefined,
            { relay: opts.relay, relayUrl, now: c.now },
          );
          if (res.sent === 0) {
            const after = deviceOfToken(c.db, c.token.id);
            throw new HttpError(
              502,
              after
                ? `The push relay couldn't deliver it (${after.lastError ?? "error"}).`
                : "The push relay doesn't know this device any more: turn notifications off and on again.",
            );
          }
          return deviceDto(deviceOfToken(c.db, c.token.id));
        },
      },
    ],
    [
      ["badge"],
      {
        GET: (c) => {
          const asked = new URL(c.req.url).searchParams.get("today");
          if (asked !== null && !isValidDate(asked)) throw new HttpError(400, "today must be YYYY-MM-DD");
          const p = (n: number) => String(n).padStart(2, "0");
          const today = asked ?? `${c.now.getFullYear()}-${p(c.now.getMonth() + 1)}-${p(c.now.getDate())}`;
          const device = deviceOfToken(c.db, c.token.id);
          return choreBadges(c.db, c.user.id, today, device ? mutedOf(device) : []);
        },
      },
    ],
  ];
}
