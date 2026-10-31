"use server";

import { revalidatePath } from "next/cache";
import { run } from "@/lib/actions/result";
import { createChannel, deleteChannel, updateChannel } from "@/lib/notifications/channels";
import { sendTestNotification } from "@/lib/notifications";
import { setPref } from "@/lib/notifications/prefs";
import { channelInputSchema } from "@/lib/notifications/schema";

function refresh(familyId: string) {
  revalidatePath(`/f/${familyId}`, "layout");
}

export const createChannelAction = async (familyId: string, input: unknown) =>
  run(({ db, user, now }) => {
    const res = createChannel(db, { id: user.id }, familyId, channelInputSchema.parse(input), now);
    refresh(familyId);
    return res;
  });

export const updateChannelAction = async (familyId: string, channelId: string, input: unknown) =>
  run(({ db, user }) => {
    updateChannel(db, { id: user.id }, familyId, channelId, channelInputSchema.parse(input));
    refresh(familyId);
  });

export const deleteChannelAction = async (familyId: string, channelId: string) =>
  run(({ db, user }) => {
    deleteChannel(db, { id: user.id }, familyId, channelId);
    refresh(familyId);
  });

/** Sends a test message right away (one short request to the provider). */
export const testChannelAction = async (familyId: string, channelId: string) =>
  run(({ db, user }) => sendTestNotification(db, { id: user.id }, familyId, channelId));

/** Turns a notification event on or off and picks its channels (phase 7). */
export const setNotificationPrefAction = async (familyId: string, input: unknown) =>
  run(({ db, user, now }) => {
    const res = setPref(db, { id: user.id }, familyId, input, now);
    refresh(familyId);
    return res;
  });
