import { z } from "zod";

export const CHANNEL_PROVIDERS = ["PUSHBULLET", "PUSHOVER", "TELEGRAM", "EMAIL", "NTFY"] as const;
export type ChannelProvider = (typeof CHANNEL_PROVIDERS)[number];

export const channelInputSchema = z.object({
  name: z.string().trim().min(1).max(100),
  provider: z.enum(CHANNEL_PROVIDERS),
  token: z.string().trim().default(""),
  target: z.string().trim().default(""),
  smtpHost: z.string().trim().default(""),
  smtpPort: z.coerce.number().int().min(1).max(65535).default(465),
  smtpUsername: z.string().trim().default(""),
  smtpFrom: z.string().trim().default(""),
  enabled: z.boolean().default(true),
});

export type ChannelInput = z.infer<typeof channelInputSchema>;

/** Fields each provider needs (the token is the secret: API key, bot token, SMTP password; for
 *  ntfy an optional access token, the target is the topic URL). */
export const CHANNEL_REQUIRED: Record<string, string[]> = {
  PUSHBULLET: ["token"],
  PUSHOVER: ["token", "target"],
  TELEGRAM: ["token", "target"],
  EMAIL: ["smtpHost", "smtpUsername", "token", "target"],
  NTFY: ["target"],
};

/** An ntfy topic URL: http(s), with a topic in the path (e.g. https://ntfy.sh/family-news). */
export function validNtfyTopicUrl(raw: string): boolean {
  try {
    const url = new URL(raw);
    return (url.protocol === "https:" || url.protocol === "http:") && url.pathname.replace(/\/+$/, "").length > 1 && !url.username && !url.password;
  } catch {
    return false;
  }
}

export function missingChannelFields(input: ChannelInput): string[] {
  const required = CHANNEL_REQUIRED[input.provider] ?? [];
  return required.filter((field) => !(input as unknown as Record<string, unknown>)[field]);
}
