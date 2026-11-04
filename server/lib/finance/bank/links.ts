// An account's link to its bank (fin_bank_links): the provider, the login (sealed), which
// account at the bank (an IBAN) or which credit card (its number's last 4 digits), the session
// a next sync may reuse, how far it is synced and the lockout guard's count. Secrets never leave
// this file opened, apart from to the runner.

import { and, eq } from "drizzle-orm";
import { HttpError } from "@/lib/api/http";
import type { Db } from "@/lib/db";
import { finBankLinks } from "@/lib/db/schema";
import { getSecretBox } from "@/lib/secrets";
import { normalizeIban } from "./comdirect";
import { providerOf } from "./providers";

export type LinkRow = typeof finBankLinks.$inferSelect;

/** Challenges in a row without a confirmed TAN after which no sync starts (comdirect locks the
 *  online banking after 5; 3 wrong TANs lock it too, and those count here as well). */
export const BANK_MAX_UNCONFIRMED = 3;

export const UNCONFIRMED_MESSAGE =
  "The bank asked for a TAN several times without one being confirmed. To keep your online banking " +
  "from being locked, log in once on the bank's website with a TAN (or save the bank connection " +
  "again), then sync again.";

export const LOGIN_REFUSED_MESSAGE =
  "The bank refused the login last time. Check the bank connection's login and PIN and save it " +
  "again (a few wrong PINs lock the online banking).";

const MAX_SECRET = 500;
const MAX_CARD = 100;
const IBAN_RE = /^[A-Z]{2}\d{2}[A-Z0-9]{10,30}$/;

export function getLink(db: Db, familyId: string, accountId: string): LinkRow | undefined {
  return db
    .select()
    .from(finBankLinks)
    .where(and(eq(finBankLinks.familyId, familyId), eq(finBankLinks.accountId, accountId)))
    .get();
}

function cleanIban(v: unknown): string | null {
  if (v === undefined || v === null || v === "") return null;
  if (typeof v !== "string") throw new HttpError(400, "iban must be a string");
  const iban = normalizeIban(v);
  if (!iban) return null;
  if (!IBAN_RE.test(iban)) throw new HttpError(400, "iban doesn't look like an IBAN");
  return iban;
}

/** A card's last 4 digits from any text holding its number or the number's end ("4871 78XX
 *  XXXX 0175", "0175"): the masked digits in between don't matter, only the end is kept. */
function cleanCard(v: unknown): string | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "string") throw new HttpError(400, "card must be a string");
  if (!v.trim()) return null;
  if (v.length > MAX_CARD) throw new HttpError(400, "card is too long");
  const digits = v.replace(/\D/g, "");
  if (digits.length < 4) throw new HttpError(400, "card needs the card number's last 4 digits");
  return digits.slice(-4);
}

/**
 * PUT …/accounts/{id}/bank {provider, <the provider's credential fields>, iban | card}: links
 * the account or changes its link. A new link (or one to another provider) needs every
 * credential; on an existing one a blank or missing one keeps the stored value. The link is to
 * an account (iban, or none: the only one there) or a credit card (card), never both: a new one
 * replaces the other, a missing one keeps the stored. Saving resets the lockout guard; a changed
 * login forgets the session, another IBAN or card starts the sync history afresh.
 */
export function saveLink(db: Db, familyId: string, accountId: string, body: Record<string, unknown>, now: Date): void {
  if (typeof body.provider !== "string") throw new HttpError(400, "provider is required");
  const provider = providerOf(body.provider);
  if (!provider) throw new HttpError(400, `Unknown bank "${body.provider}"`);
  const current = getLink(db, familyId, accountId);
  const box = getSecretBox();
  const same = current?.provider === provider.id;
  // Unreadable (the server's key changed): as if there were none, so every secret is asked for.
  const stored: Record<string, string> = (same && readCredentials(current)) || {};
  const credentials: Record<string, string> = {};
  let changed = !same;
  for (const field of provider.credentialFields) {
    const v = body[field];
    if (v !== undefined && v !== null && typeof v !== "string") throw new HttpError(400, `${field} must be a string`);
    const given = typeof v === "string" ? v.trim() : "";
    if (given.length > MAX_SECRET) throw new HttpError(400, `${field} is too long`);
    if (given) {
      if (given !== stored[field]) changed = true;
      credentials[field] = given;
    } else if (stored[field]) {
      credentials[field] = stored[field];
    } else {
      throw new HttpError(400, `${field} is required`);
    }
  }
  const givenIban = body.iban === undefined ? undefined : cleanIban(body.iban);
  const givenCard = body.card === undefined ? undefined : cleanCard(body.card);
  if (givenIban && givenCard) throw new HttpError(400, "Give either an IBAN or a card number");
  const iban = givenIban !== undefined ? givenIban : givenCard ? null : (current?.iban ?? null);
  const card = givenCard !== undefined ? givenCard : givenIban ? null : (current?.card ?? null);
  const sealed = box.seal(JSON.stringify(credentials));
  if (!current) {
    db.insert(finBankLinks)
      .values({ familyId, accountId, provider: provider.id, credentials: sealed, iban, card, createdAt: now, updatedAt: now })
      .run();
    return;
  }
  db.update(finBankLinks)
    .set({
      provider: provider.id,
      credentials: sealed,
      iban,
      card,
      unconfirmedTans: 0,
      loginRefused: false,
      ...(changed ? { session: null } : {}),
      ...(iban !== current.iban || card !== current.card || !same ? { syncedThrough: null, syncedFrom: null, bankBalanceCents: null, bankBalanceAt: null } : {}),
      updatedAt: now,
    })
    .where(and(eq(finBankLinks.familyId, familyId), eq(finBankLinks.accountId, accountId)))
    .run();
}

/** Unlinks the account (its transactions stay). */
export function deleteLink(db: Db, familyId: string, accountId: string): void {
  db.delete(finBankLinks)
    .where(and(eq(finBankLinks.familyId, familyId), eq(finBankLinks.accountId, accountId)))
    .run();
}

function readCredentials(link: LinkRow): Record<string, string> | null {
  try {
    const v = JSON.parse(getSecretBox().open(link.credentials));
    return v && typeof v === "object" ? (v as Record<string, string>) : null;
  } catch {
    return null; // never the error: it could quote the opened text
  }
}

/** The link's login, opened (the runner's only); null when it can't be read. */
export function openCredentials(link: LinkRow): Record<string, string> | null {
  return readCredentials(link);
}

/** The provider's stored session, opened; null without one or when it can't be read. */
export function openSession(link: LinkRow): unknown {
  if (!link.session) return null;
  try {
    return JSON.parse(getSecretBox().open(link.session));
  } catch {
    return null;
  }
}

export function sealSession(session: unknown): string | null {
  return session === null || session === undefined ? null : getSecretBox().seal(JSON.stringify(session));
}
