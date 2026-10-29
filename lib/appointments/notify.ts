// Appointment notifications — port of findmyappointment's notifications.ts. The channels
// and delivery are family-wide now (lib/notifications); what stays here is deciding WHAT
// to tell:
//
// Notifies ONLY on change: `changedDoctors` compares each doctor's earliest availability
// against the immediately-preceding run and reports only doctors that are newly available
// or whose earliest slot moved earlier. With `notifyOnlyEarlier`, the comparison is against
// a persistent per-search `earliestSeen` record instead, and that record only advances
// after a channel send succeeds (a total delivery failure leaves it, so the next run
// notifies again).

import { and, desc, eq, lt, ne } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { apptResults, apptRuns, apptSearches } from "@/lib/db/schema";
import { getAppUrl } from "@/lib/auth/config";
import { type Message, type Sender, notifyFamily } from "@/lib/notifications";
import { familyLocale, translator, type TFn } from "@/lib/notifications/locale";
import { channelIdsForSearch } from "./searches";

export interface SlotResult {
  doctorName: string;
  slotDatetime: Date;
}

export interface SlotDetail {
  resultId: number;
  doctorName: string;
  practiceName: string;
  motiveLabel: string;
  slotDatetime: Date;
  bookingUrl: string;
  isNextSlot: boolean;
}

export interface NotifyMessage {
  title: string;
  body: string;
  url: string;
  /** The search's page in Ohana; slot pages are `${searchUrl}/slots/<resultId>`. */
  searchUrl: string;
  slots: SlotDetail[];
}

/** The search's page in Ohana (absolute, for notifications). */
export function searchPageUrl(familyId: string, searchId: string): string {
  return `${getAppUrl()}/f/${familyId}/appointments/${searchId}`;
}

/** The new slots to advertise: every result belonging to a changed doctor, sorted by time. */
export function buildSlotList(results: SlotDetail[], changed: Map<string, Date>): SlotDetail[] {
  return results
    .filter((r) => changed.has(r.doctorName))
    .sort((a, b) => a.slotDatetime.getTime() - b.slotDatetime.getTime());
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function fmtSlot(dt: Date): string {
  return dt.toISOString().slice(0, 16).replace("T", " ");
}

/** Rich body for the email channel: every new slot with Ohana and booking links. */
export function renderEmailBody(t: TFn, msg: NotifyMessage): { text: string; html: string } {
  const marker = ` (${t("notifications.appointments.nextAvailable")})`;
  const rows = msg.slots.map((s) => ({
    label: [s.doctorName, s.practiceName, s.motiveLabel].filter(Boolean).join(" · "),
    when: fmtSlot(s.slotDatetime) + (s.isNextSlot ? marker : ""),
    appUrl: `${msg.searchUrl}/slots/${s.resultId}`,
    bookUrl: s.bookingUrl,
  }));

  const text = [
    msg.title,
    "",
    ...rows.map(
      (r) =>
        `${r.label} — ${r.when}\n${t("notifications.appointments.openInApp")}: ${r.appUrl}\n${t("notifications.appointments.book")}: ${r.bookUrl}`,
    ),
    "",
    `${t("notifications.appointments.viewAllResults")}: ${msg.url}`,
  ].join("\n");

  const openLabel = escapeHtml(t("notifications.appointments.openInApp"));
  const bookLabel = escapeHtml(t("notifications.appointments.book"));
  const btn = (href: string, label: string, primary: boolean) =>
    `<a href="${escapeHtml(href)}" style="display:inline-block;padding:8px 14px;margin:4px 6px 0 0;border-radius:6px;font-size:13px;font-weight:600;text-decoration:none;${primary ? "background:#2563eb;color:#ffffff;" : "background:#ffffff;color:#2563eb;border:1px solid #2563eb;"}">${label}</a>`;
  const cards = rows
    .map(
      (r) => `
      <tr><td style="padding:0 0 12px 0;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #e5e7eb;border-radius:10px;">
          <tr><td style="padding:14px 16px;">
            <div style="font-size:15px;font-weight:700;color:#111827;">${escapeHtml(r.label)}</div>
            <div style="font-size:13px;color:#374151;margin-top:4px;">${escapeHtml(r.when)}</div>
            <div style="margin-top:10px;">${btn(r.appUrl, openLabel, true)}${btn(r.bookUrl, bookLabel, false)}</div>
          </td></tr>
        </table>
      </td></tr>`,
    )
    .join("");
  const html = `
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f4f6;padding:24px 0;">
    <tr><td align="center">
      <table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;font-family:Arial,Helvetica,sans-serif;">
        <tr><td style="padding:0 8px 16px 8px;"><h1 style="margin:0;font-size:18px;color:#111827;">${escapeHtml(msg.title)}</h1></td></tr>
        <tr><td style="padding:0 8px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0">${cards}</table></td></tr>
        <tr><td style="padding:8px;"><a href="${escapeHtml(msg.url)}" style="font-size:13px;color:#2563eb;">${escapeHtml(t("notifications.appointments.viewAllResults"))}</a></td></tr>
      </table>
    </td></tr>
  </table>`;
  return { text, html };
}

export function earliestByDoctor(results: SlotResult[], after?: Date): Map<string, Date> {
  const earliest = new Map<string, Date>();
  for (const r of results) {
    if (after && r.slotDatetime.getTime() <= after.getTime()) continue;
    const cur = earliest.get(r.doctorName);
    if (!cur || r.slotDatetime.getTime() < cur.getTime()) earliest.set(r.doctorName, r.slotDatetime);
  }
  return earliest;
}

/** Doctors newly available or whose earliest slot moved earlier vs `previous`. */
export function changedDoctors(current: Map<string, Date>, previous: Map<string, Date>): Map<string, Date> {
  const out = new Map<string, Date>();
  for (const [doc, dt] of current) {
    const prev = previous.get(doc);
    if (!prev || dt.getTime() < prev.getTime()) out.set(doc, dt);
  }
  return out;
}

/**
 * Doctors whose earliest future slot beats the all-time `record`, plus the new record to
 * store *if* a notification is delivered. Does NOT persist.
 */
export function recordBeatingDoctors(
  currentFuture: Map<string, Date>,
  record: Date | null,
): { beaters: Map<string, Date>; newRecord: Date | null } {
  let beaters: Map<string, Date>;
  if (record === null) {
    beaters = new Map(currentFuture);
  } else {
    beaters = new Map();
    for (const [doc, dt] of currentFuture) {
      if (dt.getTime() < record.getTime()) beaters.set(doc, dt);
    }
  }
  const currentMin =
    currentFuture.size > 0 ? new Date(Math.min(...[...currentFuture.values()].map((d) => d.getTime()))) : null;
  const candidates = [record, currentMin].filter((d): d is Date => d !== null);
  const newRecord = candidates.length > 0 ? new Date(Math.min(...candidates.map((d) => d.getTime()))) : null;
  return { beaters, newRecord };
}

export function buildMessage(
  t: TFn,
  searchName: string,
  searchUrl: string,
  changed: Map<string, Date>,
  slots: SlotDetail[],
): { title: string; body: string; url: string; searchUrl: string } {
  const title = t("notifications.appointments.title", { count: changed.size, search: searchName });
  const lines = [...changed.entries()]
    .sort((a, b) => a[1].getTime() - b[1].getTime())
    .slice(0, 5)
    .map(([doc, dt]) => `${doc} — ${dt.toISOString().slice(0, 16).replace("T", " ")}`);
  // One specific slot → deep-link straight to it; multiple → the search page that lists all.
  const url = slots.length === 1 ? `${searchUrl}/slots/${slots[0].resultId}` : searchUrl;
  return { title, body: lines.join("\n"), url, searchUrl };
}

/** Loads the run + search, decides what changed, sends to the search's channels. */
export async function notifyRun(
  db: Db,
  runId: string,
  opts: { send?: Sender; now?: Date } = {},
): Promise<boolean> {
  const run = db.select().from(apptRuns).where(eq(apptRuns.id, runId)).get();
  if (!run) return false;
  const search = db.select().from(apptSearches).where(eq(apptSearches.id, run.searchId)).get();
  if (!search) return false;
  const t = translator(familyLocale(db, search.familyId));

  const results = db
    .select({
      resultId: apptResults.id,
      doctorName: apptResults.doctorName,
      slotDatetime: apptResults.slotDatetime,
      practiceName: apptResults.practiceName,
      motiveLabel: apptResults.motiveLabel,
      bookingUrl: apptResults.bookingUrl,
      isNextSlot: apptResults.isNextSlot,
    })
    .from(apptResults)
    .where(eq(apptResults.runId, runId))
    .all();

  const now = opts.now ?? new Date();
  let changed: Map<string, Date>;
  let newRecord: Date | null = null;

  if (search.notifyOnlyEarlier) {
    let record = search.earliestSeen ?? null;
    if (record && record.getTime() <= now.getTime()) record = null;
    const res = recordBeatingDoctors(earliestByDoctor(results, now), record);
    changed = res.beaters;
    newRecord = res.newRecord;
  } else {
    const current = earliestByDoctor(results);
    const prevRun = db
      .select({ id: apptRuns.id })
      .from(apptRuns)
      .where(and(eq(apptRuns.searchId, search.id), lt(apptRuns.startedAt, run.startedAt), ne(apptRuns.id, run.id)))
      .orderBy(desc(apptRuns.startedAt))
      .get();
    const prevResults = prevRun
      ? db
          .select({ doctorName: apptResults.doctorName, slotDatetime: apptResults.slotDatetime })
          .from(apptResults)
          .where(eq(apptResults.runId, prevRun.id))
          .all()
      : [];
    changed = changedDoctors(current, earliestByDoctor(prevResults));
  }

  if (changed.size === 0) return false;

  const slots = buildSlotList(results, changed);
  const msg: NotifyMessage = {
    ...buildMessage(t, search.name, searchPageUrl(search.familyId, search.id), changed, slots),
    slots,
  };
  const message: Message = { title: msg.title, body: msg.body, url: msg.url, email: renderEmailBody(t, msg) };
  const { sent } = await notifyFamily(db, search.familyId, message, {
    channelIds: channelIdsForSearch(db, search.id),
    send: opts.send,
  });

  if (sent > 0) {
    db.update(apptRuns).set({ notified: true }).where(eq(apptRuns.id, runId)).run();
    if (search.notifyOnlyEarlier && newRecord?.getTime() !== search.earliestSeen?.getTime()) {
      db.update(apptSearches).set({ earliestSeen: newRecord }).where(eq(apptSearches.id, search.id)).run();
    }
  }
  return sent > 0;
}
