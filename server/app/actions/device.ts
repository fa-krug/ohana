"use server";

import { pairDevice } from "@/lib/auth/device-pairing";
import { run } from "@/lib/actions/result";

/** Gives the native app an API token (see lib/auth/device-pairing.ts). */
export const pairDeviceAction = async (state: string, deviceName: string) =>
  run(({ db, user, now }) => pairDevice(db, user.id, { state, deviceName }, now));
