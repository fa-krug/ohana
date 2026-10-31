// Delivery to one channel — port of findmyappointment's senders (Pushbullet, Pushover,
// Telegram, email over SMTP), plus ntfy (self-hostable push). Network code; only the ntfy
// request is built by a tested function.

import nodemailer from "nodemailer";
import { timeoutSignal } from "@/lib/appointments/http";

/** A notification, independent of the module that sends it. */
export interface Message {
  title: string;
  /** Plain text, a few lines. */
  body: string;
  /** Where the notification leads (deep link into Ohana). */
  url: string;
  /** A richer email body; otherwise the email is built from title, body and url. */
  email?: { text: string; html: string };
}

/** A channel with its secret opened. */
export interface Channel {
  provider: string;
  token: string;
  target: string;
  smtpHost: string;
  smtpPort: number;
  smtpUsername: string;
  smtpFrom: string;
}

async function sendPushbullet(c: Channel, msg: Message): Promise<void> {
  const res = await fetch("https://api.pushbullet.com/v2/pushes", {
    method: "POST",
    headers: { "Access-Token": c.token, "Content-Type": "application/json" },
    body: JSON.stringify({ type: "link", title: msg.title, body: msg.body, url: msg.url }),
    signal: timeoutSignal(),
  });
  if (!res.ok) throw new Error(`pushbullet ${res.status}`);
}

async function sendPushover(c: Channel, msg: Message): Promise<void> {
  const res = await fetch("https://api.pushover.net/1/messages.json", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ token: c.token, user: c.target, title: msg.title, message: msg.body || msg.title, url: msg.url }),
    signal: timeoutSignal(),
  });
  if (!res.ok) throw new Error(`pushover ${res.status}`);
}

async function sendTelegram(c: Channel, msg: Message): Promise<void> {
  const text = [msg.title, msg.body, msg.url].filter(Boolean).join("\n\n");
  const res = await fetch(`https://api.telegram.org/bot${c.token}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ chat_id: c.target, text }),
    signal: timeoutSignal(),
  });
  if (!res.ok) throw new Error(`telegram ${res.status}`);
}

/** The request that publishes a message to an ntfy topic (JSON publishing isn't used: it needs
 *  the server's root URL and the topic apart, a topic URL is simpler to configure). */
export function ntfyRequest(c: Channel, msg: Message): { url: string; init: RequestInit } {
  const headers: Record<string, string> = { "Content-Type": "text/plain; charset=utf-8" };
  // Header values must be ISO-8859-1: ntfy decodes RFC 2047 encoded words, so the title can
  // carry umlauts and emoji.
  headers.Title = /^[\x20-\x7e]*$/.test(msg.title) ? msg.title : `=?UTF-8?B?${Buffer.from(msg.title, "utf8").toString("base64")}?=`;
  if (msg.url) headers.Click = msg.url;
  if (c.token) headers.Authorization = `Bearer ${c.token}`;
  return { url: c.target, init: { method: "POST", headers, body: msg.body || msg.title } };
}

async function sendNtfy(c: Channel, msg: Message): Promise<void> {
  const { url, init } = ntfyRequest(c, msg);
  const res = await fetch(url, { ...init, signal: timeoutSignal() });
  if (!res.ok) throw new Error(`ntfy ${res.status}`);
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** The email body for a message without its own (`msg.email`). */
export function plainEmail(msg: Message): { text: string; html: string } {
  const text = [msg.title, "", msg.body, "", msg.url].join("\n").trim();
  const body = escapeHtml(msg.body).replace(/\n/g, "<br>");
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#111827;">
  <h1 style="font-size:18px;margin:0 0 12px 0;">${escapeHtml(msg.title)}</h1>
  ${body ? `<p style="margin:0 0 12px 0;">${body}</p>` : ""}
  ${msg.url ? `<p><a href="${escapeHtml(msg.url)}" style="color:#2563eb;">${escapeHtml(msg.url)}</a></p>` : ""}
</div>`;
  return { text, html };
}

async function sendEmail(c: Channel, msg: Message): Promise<void> {
  const port = c.smtpPort || 465;
  const transport = nodemailer.createTransport({
    host: c.smtpHost,
    port,
    secure: port === 465, // implicit TLS on 465
    requireTLS: port !== 465, // enforce STARTTLS on other ports — never send AUTH in plaintext
    auth: { user: c.smtpUsername, pass: c.token },
    connectionTimeout: 30_000,
    socketTimeout: 30_000,
  });
  const { text, html } = msg.email ?? plainEmail(msg);
  await transport.sendMail({ from: c.smtpFrom || c.smtpUsername, to: c.target, subject: msg.title, text, html });
}

const SENDERS: Record<string, (c: Channel, msg: Message) => Promise<void>> = {
  PUSHBULLET: sendPushbullet,
  PUSHOVER: sendPushover,
  TELEGRAM: sendTelegram,
  EMAIL: sendEmail,
  NTFY: sendNtfy,
};

/** Sends to one channel; throws on failure. */
export async function deliver(c: Channel, msg: Message): Promise<void> {
  const send = SENDERS[c.provider];
  if (!send) throw new Error(`unknown provider ${c.provider}`);
  await send(c, msg);
}
