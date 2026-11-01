// The notification events (phase 7), shared by the server (prefs.ts) and the settings page.

export const NOTIFY_EVENTS = ["appointment_found", "coverage_gap", "assistant_turn_finished", "weekly_digest"] as const;
export type NotifyEvent = (typeof NOTIFY_EVENTS)[number];

/** On unless turned off, except the assistant's finished turns (the channels are the family's,
 *  the chat one person's). */
export const DEFAULT_ENABLED: Record<NotifyEvent, boolean> = {
  appointment_found: true,
  coverage_gap: true,
  assistant_turn_finished: false,
  weekly_digest: true,
};

/** Appointment searches choose their channels themselves; the others here. */
export const EVENT_HAS_CHANNELS: Record<NotifyEvent, boolean> = {
  appointment_found: false,
  coverage_gap: true,
  assistant_turn_finished: true,
  weekly_digest: true,
};

export interface EventPref {
  event: NotifyEvent;
  enabled: boolean;
  /** null: all of the family's enabled channels. */
  channelIds: string[] | null;
  /** Also push to the members' app devices (phase 9). */
  app: boolean;
}
