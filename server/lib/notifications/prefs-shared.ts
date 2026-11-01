// The notification events (phase 7), shared by the server (prefs.ts) and the settings page.

export const NOTIFY_EVENTS = ["appointment_found", "coverage_gap", "shopping_reminder", "assistant_turn_finished"] as const;
export type NotifyEvent = (typeof NOTIFY_EVENTS)[number];

/** On unless turned off, except the shopping reminder (one message per shopping trip) and the
 *  assistant's finished turns (the channels are the family's, the chat one person's). */
export const DEFAULT_ENABLED: Record<NotifyEvent, boolean> = {
  appointment_found: true,
  coverage_gap: true,
  shopping_reminder: false,
  assistant_turn_finished: false,
};

/** Appointment searches choose their channels themselves; the others here. */
export const EVENT_HAS_CHANNELS: Record<NotifyEvent, boolean> = {
  appointment_found: false,
  coverage_gap: true,
  shopping_reminder: true,
  assistant_turn_finished: true,
};

export interface EventPref {
  event: NotifyEvent;
  enabled: boolean;
  /** null: all of the family's enabled channels. */
  channelIds: string[] | null;
  /** Also push to the members' app devices (phase 9). */
  app: boolean;
}
