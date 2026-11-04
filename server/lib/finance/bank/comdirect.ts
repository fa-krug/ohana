// comdirect's REST API for private customers (https://api.comdirect.de): login with the API
// credentials (client id / secret from the online banking) and the Zugangsnummer + PIN, a TAN
// for the session (push in the comdirect app, or a photoTAN / SMS TAN the user types), then the
// account's booked transactions (setting it up: docs/app.md, "Syncing an account with its bank").
//
// comdirect LOCKS the online banking after 5 TAN challenges without a confirmed TAN, or 3 wrong
// TANs. So: requests run one after the other, the TAN request (validate) and the TAN itself
// (PATCH) are never retried, and the hooks count every challenge before it is asked for (the
// runner refuses to start a sync after a few unconfirmed ones). A stored refresh token (about
// 20 minutes) lets a sync soon after the last skip the TAN.

import { randomBytes } from "node:crypto";
import { setTimeout as sleep } from "node:timers/promises";
import { isValidDate } from "@/lib/calendar/dates";
import { BankError, type BankProvider, type BankRow, type BankStatement, type SyncRequest } from "./types";

export const COMDIRECT_BASE = "https://api.comdirect.de";
/** How long comdirect keeps a refresh token (unofficial: about 20 minutes). */
const SESSION_MS = 19 * 60_000;
/** Transactions per page (comdirect's maximum). */
const PAGE = 500;
const MAX_PAGES = 100;
const MAX_PAYEE = 200;
const MAX_DESCRIPTION = 500;
const MAX_CENTS = 100_000_000_000_000;

/** What the next sync may reuse: the banking token's refresh token. */
interface Session {
  refreshToken: string;
  expiresAt: number; // ms
}

interface Tokens {
  access: string;
  refresh: string;
}

/** A 401 on a banking call: the token is gone (a refreshed one that didn't hold). */
class Expired extends Error {}

/** One sync's connection: request ids, timeouts, sequential calls. */
class Api {
  private readonly sessionId = randomBytes(16).toString("hex");
  private lastRequestId = -1;

  constructor(
    private readonly req: SyncRequest,
    private readonly base = COMDIRECT_BASE,
  ) {}

  /** HHmmssSSS, unique within the session. */
  private requestId(): string {
    const d = this.req.now();
    let n = d.getHours() * 1e7 + d.getMinutes() * 1e5 + d.getSeconds() * 1e3 + d.getMilliseconds();
    if (n <= this.lastRequestId) n = (this.lastRequestId + 1) % 1e9;
    this.lastRequestId = n;
    return String(n).padStart(9, "0");
  }

  async call(
    method: string,
    path: string,
    opts: { token?: string; form?: Record<string, string>; json?: unknown; headers?: Record<string, string>; retry?: boolean } = {},
  ): Promise<Response> {
    const headers: Record<string, string> = { accept: "application/json", ...opts.headers };
    let body: string | undefined;
    if (opts.form) {
      headers["content-type"] = "application/x-www-form-urlencoded";
      body = new URLSearchParams(opts.form).toString();
    } else if (opts.json !== undefined) {
      headers["content-type"] = "application/json";
      body = JSON.stringify(opts.json);
    }
    if (opts.token) {
      headers.authorization = `Bearer ${opts.token}`;
      headers["x-http-request-info"] = JSON.stringify({
        clientRequestId: { sessionId: this.sessionId, requestId: this.requestId() },
      });
    }
    // Only reads are tried again, and only when comdirect asks to slow down.
    for (let attempt = 0; ; attempt++) {
      const timeout = AbortSignal.timeout(this.req.timing.requestTimeoutMs);
      let res: Response;
      try {
        res = await this.req.fetch(this.base + path, {
          method,
          headers,
          body,
          signal: AbortSignal.any([this.req.signal, timeout]),
        });
      } catch (err) {
        if (this.req.signal.aborted) throw err;
        if (timeout.aborted) throw new BankError("comdirect didn't answer in time");
        throw new BankError("comdirect can't be reached");
      }
      if (res.status === 429 && opts.retry && attempt < 2) {
        await res.body?.cancel();
        await sleep(1000 * (attempt + 1), undefined, { signal: this.req.signal });
        continue;
      }
      return res;
    }
  }

  async json(res: Response): Promise<unknown> {
    try {
      return await res.json();
    } catch {
      if (this.req.signal.aborted) throw this.req.signal.reason;
      throw new BankError("comdirect sent an answer Ohana can't read");
    }
  }

  /** POST /oauth/token with the API credentials and `grant`. */
  async token(grant: Record<string, string>): Promise<{ status: number; tokens: Tokens | null; error: string }> {
    const { clientId, clientSecret } = this.req.credentials;
    const res = await this.call("POST", "/oauth/token", {
      form: { client_id: clientId, client_secret: clientSecret, ...grant },
    });
    if (!res.ok) {
      let error = "";
      try {
        const body = (await res.json()) as { error?: unknown };
        if (typeof body?.error === "string") error = body.error;
      } catch {
        // no OAuth error body
      }
      return { status: res.status, tokens: null, error };
    }
    const body = (await this.json(res)) as { access_token?: unknown; refresh_token?: unknown };
    if (typeof body?.access_token !== "string" || typeof body.refresh_token !== "string") {
      throw new BankError("comdirect sent no access token");
    }
    return { status: res.status, tokens: { access: body.access_token, refresh: body.refresh_token }, error: "" };
  }
}

function isSession(v: unknown): v is Session {
  const s = v as Session;
  return !!s && typeof s.refreshToken === "string" && typeof s.expiresAt === "number";
}

/** Keeps the banking token's refresh token for the next sync. */
function keep(req: SyncRequest, tokens: Tokens) {
  req.hooks.saveSession({ refreshToken: tokens.refresh, expiresAt: req.now().getTime() + SESSION_MS } satisfies Session);
}

/** The banking token from the stored session, or null when it can't be refreshed. */
async function refreshed(api: Api, req: SyncRequest): Promise<string | null> {
  const session = req.session;
  if (!isSession(session) || session.expiresAt <= req.now().getTime() + 30_000) return null;
  req.hooks.step("login");
  const { tokens } = await api.token({ grant_type: "refresh_token", refresh_token: session.refreshToken });
  if (!tokens) {
    req.hooks.saveSession(null);
    return null;
  }
  keep(req, tokens);
  return tokens.access;
}

function parseHeader(value: string | null): Record<string, unknown> | null {
  if (!value) return null;
  try {
    const v = JSON.parse(value);
    return v && typeof v === "object" ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/** The full login: password grant, session, TAN challenge, TAN, banking token. */
async function login(api: Api, req: SyncRequest): Promise<string> {
  const { hooks } = req;
  hooks.step("login");
  const { username, pin } = req.credentials;
  const primary = await api.token({ grant_type: "password", username, password: pin });
  if (!primary.tokens) {
    if (primary.status === 400 || primary.status === 401) hooks.loginRefused();
    if (primary.status === 401 || primary.error === "invalid_client" || primary.error === "unauthorized_client") {
      throw new BankError("comdirect refused the API access: check the client ID and secret");
    }
    if (primary.status === 400) {
      throw new BankError("comdirect refused the login: check the Zugangsnummer (login) and PIN");
    }
    throw new BankError(`comdirect refused the login (${primary.status})`);
  }
  const token = primary.tokens.access;
  const res = await api.call("GET", "/api/session/clients/user/v1/sessions", { token, retry: true });
  if (!res.ok) throw new BankError(`comdirect didn't open a session (${res.status})`);
  const sessions = await api.json(res);
  const identifier = Array.isArray(sessions) ? (sessions[0] as { identifier?: unknown })?.identifier : undefined;
  if (typeof identifier !== "string" || !identifier) throw new BankError("comdirect didn't open a session");
  const session = `/api/session/clients/user/v1/sessions/${encodeURIComponent(identifier)}`;
  const body = { identifier, sessionTanActive: true, activated2FA: true };

  // The TAN challenge: counted first, never asked for twice.
  hooks.challenging();
  const validate = await api.call("POST", `${session}/validate`, {
    token,
    json: body,
    headers: { "x-once-authentication-info": JSON.stringify({ typ: "P_TAN_PUSH" }) },
  });
  await validate.body?.cancel();
  if (!validate.ok) throw new BankError(`comdirect didn't ask for a TAN (${validate.status})`);
  const info = parseHeader(validate.headers.get("x-once-authentication-info"));
  const id = info?.id;
  if (typeof id !== "string" && typeof id !== "number") throw new BankError("comdirect didn't ask for a TAN");
  const challenge = typeof info?.challenge === "string" ? info.challenge : null;
  let tan: string | null = null;
  switch (info?.typ) {
    case "P_TAN_PUSH": {
      hooks.challenge({ type: "push", image: null, hint: null });
      const link = info.link as { href?: unknown } | undefined;
      await approved(api, req, token, typeof link?.href === "string" ? link.href : null);
      break;
    }
    case "P_TAN":
      hooks.challenge({ type: "photo", image: challenge, hint: null });
      tan = await hooks.waitForTan(req.timing.tanTimeoutMs);
      break;
    case "M_TAN":
      hooks.challenge({ type: "sms", image: null, hint: challenge });
      tan = await hooks.waitForTan(req.timing.tanTimeoutMs);
      break;
    default:
      throw new BankError(`comdirect asked for a TAN method Ohana doesn't support (${String(info?.typ)})`);
  }

  // The TAN (or the approval) once: a wrong one is not tried again.
  hooks.confirming();
  const patch = await api.call("PATCH", session, {
    token,
    json: body,
    headers: {
      "x-once-authentication-info": JSON.stringify({ id: String(id) }),
      ...(tan !== null ? { "x-once-authentication": tan } : {}),
    },
  });
  await patch.body?.cancel();
  if (!patch.ok) {
    if (patch.status === 400 || patch.status === 422) {
      throw new BankError(
        tan !== null
          ? "comdirect didn't accept the TAN. Check it and start the sync again for a new one."
          : "comdirect didn't accept the approval. Start the sync again.",
      );
    }
    throw new BankError(`comdirect didn't accept the TAN (${patch.status})`);
  }
  hooks.confirmed();

  const secondary = await api.token({ grant_type: "cd_secondary", token });
  if (!secondary.tokens) throw new BankError(`comdirect didn't open the banking access (${secondary.status})`);
  keep(req, secondary.tokens);
  return secondary.tokens.access;
}

/** Waits until the login is approved in the comdirect app (polls the challenge's link). */
async function approved(api: Api, req: SyncRequest, token: string, href: string | null): Promise<void> {
  if (!href || !href.startsWith("/")) {
    throw new BankError("comdirect asked for an approval in its app but gave no way to check it. Try again later.");
  }
  const until = Date.now() + req.timing.tanTimeoutMs;
  for (;;) {
    await sleep(req.timing.pushPollMs, undefined, { signal: req.signal });
    const res = await api.call("GET", href, { token, retry: true });
    if (res.ok) {
      const status = ((await api.json(res)) as { status?: unknown })?.status;
      if (status === "AUTHENTICATED") return;
      if (status !== "PENDING") throw new BankError("The login wasn't approved in the comdirect app");
    } else {
      await res.body?.cancel();
      if (res.status < 500) throw new BankError("comdirect ended the approval. Start the sync again.");
    }
    if (Date.now() >= until) throw new BankError("The login wasn't approved in time");
  }
}

// ------------------------------------------------------------------ data

/** No spaces, upper case. */
export function normalizeIban(iban: string): string {
  return iban.replace(/\s+/g, "").toUpperCase();
}

interface BankAccount {
  id: string;
  iban: string | null;
  type: string;
  typeText: string;
}

function accountsOf(body: unknown): BankAccount[] {
  const values = (body as { values?: unknown })?.values;
  if (!Array.isArray(values)) return [];
  return values.flatMap((v) => {
    const account = (v?.account ?? {}) as Record<string, unknown>;
    const id = v?.accountId ?? account.accountId;
    if (typeof id !== "string" || !id) return [];
    const type = (account.accountType ?? {}) as Record<string, unknown>;
    return [{
      id,
      iban: typeof account.iban === "string" && account.iban ? normalizeIban(account.iban) : null,
      type: typeof type.key === "string" ? type.key : "",
      typeText: typeof type.text === "string" ? type.text : "",
    }];
  });
}

/** The linked account: by IBAN, else the only Girokonto. */
export function pickAccount(accounts: BankAccount[], iban: string | null): BankAccount {
  const list = () => accounts.map((a) => `${a.iban ?? a.id} (${a.typeText || a.type || "?"})`).join(", ");
  if (iban) {
    const found = accounts.find((a) => a.iban === iban);
    if (found) return found;
    throw new BankError(
      accounts.length
        ? `comdirect has no account with the IBAN ${iban}. Its accounts: ${list()}`
        : `comdirect has no account with the IBAN ${iban}`,
    );
  }
  const giro = accounts.filter((a) => a.type === "CA");
  if (giro.length === 1) return giro[0];
  if (!accounts.length) throw new BankError("comdirect lists no accounts");
  throw new BankError(`Set the IBAN of the account in the bank connection: comdirect has ${list()}`);
}

async function statement(api: Api, req: SyncRequest, token: string): Promise<BankStatement> {
  req.hooks.step("fetch");
  const res = await api.call("GET", "/api/banking/clients/user/v2/accounts/balances", { token, retry: true });
  if (res.status === 401) {
    await res.body?.cancel();
    throw new Expired();
  }
  if (!res.ok) throw new BankError(`comdirect didn't list the accounts (${res.status})`);
  const account = pickAccount(accountsOf(await api.json(res)), req.iban);
  const rows: BankRow[] = [];
  let first = 0;
  for (let page = 0; page < MAX_PAGES; page++) {
    const query = new URLSearchParams({
      transactionState: "BOOKED",
      "paging-first": String(first),
      "paging-count": String(PAGE),
      "min-bookingDate": req.from,
    });
    const r = await api.call("GET", `/api/banking/v1/accounts/${encodeURIComponent(account.id)}/transactions?${query}`, {
      token,
      retry: true,
    });
    if (r.status === 401) {
      await r.body?.cancel();
      throw new Expired();
    }
    if (!r.ok) throw new BankError(`comdirect didn't list the transactions (${r.status})`);
    const body = (await api.json(r)) as { values?: unknown; paging?: { matches?: unknown } };
    const values = Array.isArray(body?.values) ? body.values : [];
    for (const v of values) {
      const row = mapTransaction(v);
      // The filter isn't reliable everywhere: the days are checked here too.
      if (row && row.day >= req.from) rows.push(row);
    }
    first += values.length;
    const matches = typeof body?.paging?.matches === "number" ? body.paging.matches : 0;
    if (values.length < PAGE || first >= matches) break;
  }
  return { accountRef: account.id, rows };
}

// ------------------------------------------------------------------ mapping

/** Exact cents of a decimal string ("-12.34"); null when it isn't one. */
export function centsOf(v: unknown): number | null {
  if (typeof v === "number") return Number.isFinite(v) && Math.abs(v) * 100 <= MAX_CENTS ? Math.round(v * 100) : null;
  if (typeof v !== "string") return null;
  const m = /^\s*([+-]?)(\d+)(?:\.(\d+))?\s*$/.exec(v);
  if (!m) return null;
  const frac = (m[3] ?? "").padEnd(3, "0");
  let cents = BigInt(m[2]) * 100n + BigInt(frac.slice(0, 2));
  if (Number(frac[2]) >= 5) cents += 1n; // half away from zero
  if (cents > BigInt(MAX_CENTS)) return null;
  const n = Number(cents);
  return m[1] === "-" && n ? -n : n;
}

const REFERENCE_LABELS = [
  /^End-to-End-Ref\.?:/i,
  /^(?:CORE|COR1|B2B) \/ Mandatsref\.?:/i,
  /^Mandatsref\.?:/i,
  /^Gl(?:ä|ae)ubiger-ID:/i,
];

const squash = (s: string) => s.split(/\s+/).filter(Boolean).join(" ");

/**
 * The lines of a remittanceInfo: booked rows come as windows of 37 characters (a 2-digit line
 * number and 35 of text, padded with spaces), or with newlines. A window filled to its end
 * continues on the next ("AMZN.COM BI" + "LL LU"). The SEPA references ("End-to-End-Ref.:",
 * "CORE / Mandatsref.:", "Gläubiger-ID:", each followed by its value on the next line) are
 * left out.
 */
export function remittanceLines(info: unknown): string[] {
  if (typeof info !== "string" || !info.trim()) return [];
  let windows: { text: string; full: boolean }[];
  if (info.includes("\n")) {
    windows = info.split("\n").map((l) => ({ text: l, full: false }));
  } else if (/^01/.test(info)) {
    windows = [];
    for (let i = 0; i < info.length; i += 37) {
      const w = info.slice(i, i + 37);
      const text = /^\d\d/.test(w) ? w.slice(2) : w;
      windows.push({ text, full: text.length === 35 && !/\s$/.test(text) });
    }
  } else {
    windows = [{ text: info, full: false }];
  }
  const lines: string[] = [];
  let joinNext = false;
  for (let i = 0; i < windows.length; i++) {
    const text = squash(windows[i].text);
    const label = REFERENCE_LABELS.find((re) => re.test(text));
    if (label) {
      // The label and its value (on the same line, or the next one).
      if (!text.replace(label, "").trim()) i++;
      joinNext = false;
      continue;
    }
    if (!text) {
      joinNext = false;
      continue;
    }
    if (joinNext && lines.length && !/^\s/.test(windows[i].text)) lines[lines.length - 1] += text;
    else if (joinNext && lines.length) lines[lines.length - 1] += ` ${text}`;
    else lines.push(text);
    joinNext = windows[i].full;
  }
  return lines;
}

function holder(p: unknown): string {
  const name = (p as { holderName?: unknown } | null)?.holderName;
  return typeof name === "string" ? squash(name) : "";
}

function clip(s: string, max: number): string {
  return s.length > max ? s.slice(0, max).trim() : s;
}

/** A booked transaction of comdirect's list as a row; null for one without a day or amount, or
 *  not booked yet. */
export function mapTransaction(raw: unknown): BankRow | null {
  const t = raw as Record<string, unknown> | null;
  if (!t || typeof t !== "object") return null;
  if (t.bookingStatus !== undefined && t.bookingStatus !== "BOOKED") return null;
  const day = t.bookingDate;
  if (typeof day !== "string" || !isValidDate(day)) return null;
  const amountCents = centsOf((t.amount as { value?: unknown } | null)?.value);
  if (amountCents === null) return null;
  const type = (t.transactionType ?? {}) as { key?: unknown; text?: unknown };
  const typeText = typeof type.text === "string" ? squash(type.text) : "";
  const debtor = holder(t.deptor) || holder(t.debtor);
  // Outgoing: who got it (creditor); a direct debit: who collected it (remitter); incoming: who
  // sent it (remitter).
  let payee = type.key === "DIRECT_DEBIT"
    ? holder(t.remitter) || holder(t.creditor) || debtor
    : amountCents < 0
      ? holder(t.creditor) || debtor
      : holder(t.remitter) || debtor;
  const lines = remittanceLines(t.remittanceInfo);
  // A card payment names nobody: the merchant is the first line.
  if (!payee && lines.length) payee = lines.shift()!;
  if (!payee) payee = typeText;
  let description = lines.join(" ");
  if (!description && typeText !== payee) description = typeText;
  const reference = typeof t.reference === "string" && t.reference.trim() ? t.reference.trim() : null;
  return {
    day,
    amountCents,
    payee: clip(payee, MAX_PAYEE),
    description: clip(description, MAX_DESCRIPTION),
    reference,
  };
}

// ------------------------------------------------------------------ the provider

export const comdirect: BankProvider = {
  id: "comdirect",
  credentialFields: ["clientId", "clientSecret", "username", "pin"],
  async fetchStatement(req: SyncRequest): Promise<BankStatement> {
    const api = new Api(req);
    const token = await refreshed(api, req);
    if (token) {
      try {
        return await statement(api, req, token);
      } catch (err) {
        if (!(err instanceof Expired)) throw err;
        req.hooks.saveSession(null);
      }
    }
    try {
      return await statement(api, req, await login(api, req));
    } catch (err) {
      if (err instanceof Expired) throw new BankError("comdirect ended the session. Start the sync again.");
      throw err;
    }
  },
};
