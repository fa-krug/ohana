import { z } from "zod";

export const CHANNEL_PROVIDERS = ["PUSHBULLET", "PUSHOVER", "TELEGRAM", "EMAIL"] as const;
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

/** Fields each provider needs (the token is the secret: API key, bot token, SMTP password). */
export const CHANNEL_REQUIRED: Record<string, string[]> = {
  PUSHBULLET: ["token"],
  PUSHOVER: ["token", "target"],
  TELEGRAM: ["token", "target"],
  EMAIL: ["smtpHost", "smtpUsername", "token", "target"],
};

export function missingChannelFields(input: ChannelInput): string[] {
  const required = CHANNEL_REQUIRED[input.provider] ?? [];
  return required.filter((field) => !(input as unknown as Record<string, unknown>)[field]);
}
