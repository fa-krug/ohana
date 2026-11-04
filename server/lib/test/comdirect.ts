// A fake comdirect REST API for tests (no network): a fetch that keeps state like the real one
// (tokens, the session, the TAN challenge, accounts and transactions with paging, credit cards
// and their transactions without paging, as comdirect's undocumented card endpoints) and checks
// what the client sends (headers, the challenge id, the TAN). See lib/finance/bank/comdirect.ts.

export const FAKE_PHOTO_TAN = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

export interface FakeAccount {
  accountId: string;
  iban: string;
  type: string; // CA, DAS, …
  text: string;
  /** Its booked balance (Kontostand), a decimal string; default "100.00". */
  balance?: string;
  /** What's available (booked minus pending); default the balance. */
  available?: string;
}

export interface FakeCard {
  cardId: string;
  /** The last 4 digits of its number. */
  suffix: string;
  holder: string;
  /** Its booked balance, a decimal string; default "-12.34". */
  balance?: string;
}

export interface FakeComdirectOptions {
  clientId: string;
  clientSecret: string;
  username: string;
  pin: string;
  /** The TAN method comdirect answers with. */
  tanType: "P_TAN_PUSH" | "P_TAN" | "M_TAN";
  /** The TAN a photoTAN / SMS challenge takes. */
  tan: string;
  /** Push: approved after this many polls; null: only by approve(). */
  approveAfter: number | null;
  /** Push: the approval is declined. */
  declinePush: boolean;
  /** No link in a push challenge. */
  pushWithoutLink: boolean;
  accounts: FakeAccount[];
  /** Raw AccountTransaction objects per accountId, newest first. */
  transactions: Record<string, unknown[]>;
  cards: FakeCard[];
  /** Raw card transaction objects per cardId, newest first. */
  cardTransactions: Record<string, unknown[]>;
}

export const GIRO: FakeAccount = { accountId: "ACC-GIRO", iban: "DE89370400440532013000", type: "CA", text: "Girokonto" };
export const VISA: FakeCard = { cardId: "CARD-1", suffix: "0175", holder: "Max Mustermann" };
export const VISA_2: FakeCard = { cardId: "CARD-2", suffix: "0183", holder: "Erika Mustermann" };
export const SAVINGS: FakeAccount = { accountId: "ACC-TG", iban: "DE02120300000000202051", type: "DAS", text: "Tagesgeld PLUS" };

export interface FakeComdirectState {
  /** "METHOD path" of every request. */
  calls: string[];
  /** Problems with what the client sent (a test fails when there are any). */
  problems: string[];
  validates: number;
  patches: number;
  pushPolls: number;
  refreshes: number;
  /** The TANs the PATCHes carried (null: none). */
  tans: (string | null)[];
  /** min-bookingDate of each transactions request (of accounts and cards). */
  minBookingDates: string[];
}

/** One windowed remittanceInfo line: a 2-digit number and 35 characters. */
export function remittance(...lines: string[]): string {
  return lines.map((l, i) => String(i + 1).padStart(2, "0") + l.padEnd(35).slice(0, 35)).join("");
}

export function fakeComdirect(overrides: Partial<FakeComdirectOptions> = {}) {
  const opts: FakeComdirectOptions = {
    clientId: "client-id",
    clientSecret: "client-secret",
    username: "12345678",
    pin: "4711",
    tanType: "P_TAN_PUSH",
    tan: "123456",
    approveAfter: 1,
    declinePush: false,
    pushWithoutLink: false,
    accounts: [GIRO],
    transactions: {},
    cards: [],
    cardTransactions: {},
    ...overrides,
  };
  const state: FakeComdirectState = {
    calls: [],
    problems: [],
    validates: 0,
    patches: 0,
    pushPolls: 0,
    refreshes: 0,
    tans: [],
    minBookingDates: [],
  };
  let n = 0;
  const primary = new Map<string, { activated: boolean }>();
  const banking = new Set<string>();
  const refresh = new Set<string>();
  let challenge: { id: string; auth: string; approved: boolean; polls: number } | null = null;
  const requestIds = new Set<string>();

  const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
  const empty = (status: number) => new Response(null, { status });

  function checkApiHeaders(headers: Headers): string | null {
    if (headers.get("accept") !== "application/json") state.problems.push("accept header missing");
    const info = headers.get("x-http-request-info");
    try {
      const parsed = JSON.parse(info ?? "");
      const { sessionId, requestId } = parsed.clientRequestId;
      if (!/^[0-9a-f]{32}$/.test(sessionId)) state.problems.push(`bad sessionId ${sessionId}`);
      if (!/^\d{9}$/.test(requestId)) state.problems.push(`bad requestId ${requestId}`);
      if (requestIds.has(`${sessionId}/${requestId}`)) state.problems.push(`requestId ${requestId} used twice`);
      requestIds.add(`${sessionId}/${requestId}`);
    } catch {
      state.problems.push("x-http-request-info missing");
    }
    const m = /^Bearer (\S+)$/.exec(headers.get("authorization") ?? "");
    return m ? m[1] : null;
  }

  function issue(kind: "p" | "s") {
    n += 1;
    const access = `${kind}-access-${n}`;
    const refreshToken = `${kind}-refresh-${n}`;
    if (kind === "p") primary.set(access, { activated: false });
    else {
      banking.add(access);
      refresh.add(refreshToken);
    }
    return json({
      access_token: access,
      token_type: "bearer",
      refresh_token: refreshToken,
      expires_in: 599,
      scope: kind === "p" ? "TWO_FACTOR" : "BANKING_RO",
    });
  }

  function token(form: URLSearchParams): Response {
    if (form.get("client_id") !== opts.clientId || form.get("client_secret") !== opts.clientSecret) {
      return json({ error: "invalid_client", error_description: "Bad client credentials" }, 401);
    }
    switch (form.get("grant_type")) {
      case "password":
        if (form.get("username") !== opts.username || form.get("password") !== opts.pin) {
          return json({ error: "invalid_grant", error_description: "Bad credentials" }, 400);
        }
        return issue("p");
      case "cd_secondary": {
        const p = primary.get(form.get("token") ?? "");
        if (!p?.activated) return json({ error: "invalid_grant" }, 400);
        return issue("s");
      }
      case "refresh_token": {
        const r = form.get("refresh_token") ?? "";
        if (!refresh.has(r)) return json({ error: "invalid_grant" }, 400);
        refresh.delete(r);
        state.refreshes += 1;
        return issue("s");
      }
      default:
        return json({ error: "unsupported_grant_type" }, 400);
    }
  }

  async function handle(method: string, url: URL, headers: Headers, body: string): Promise<Response> {
    const path = url.pathname;
    if (method === "POST" && path === "/oauth/token") {
      if (headers.get("content-type") !== "application/x-www-form-urlencoded") state.problems.push("token: content type");
      return token(new URLSearchParams(body));
    }
    if (!path.startsWith("/api/")) return empty(404);
    const bearer = checkApiHeaders(headers);
    const session = "/api/session/clients/user/v1/sessions";
    if (path.startsWith("/api/session/")) {
      const p = bearer ? primary.get(bearer) : undefined;
      if (!p) return empty(401);
      if (method === "GET" && path === session) {
        return json([{ identifier: "SESSION-1", sessionTanActive: false, activated2FA: false }]);
      }
      if (method === "POST" && path === `${session}/SESSION-1/validate`) {
        state.validates += 1;
        const asked = JSON.parse(headers.get("x-once-authentication-info") ?? "{}");
        if (asked.typ !== "P_TAN_PUSH") state.problems.push(`validate asked for ${asked.typ}`);
        const id = String(600000000 + state.validates);
        challenge = { id, auth: `AUTH-${state.validates}`, approved: false, polls: 0 };
        const info: Record<string, unknown> = { id, typ: opts.tanType, availableTypes: ["P_TAN_PUSH", "P_TAN"] };
        if (opts.tanType === "P_TAN_PUSH" && !opts.pushWithoutLink) {
          info.link = { href: `/api/session/v1/authentications/${challenge.auth}`, rel: "related", method: "GET" };
        }
        if (opts.tanType === "P_TAN") info.challenge = FAKE_PHOTO_TAN;
        if (opts.tanType === "M_TAN") info.challenge = "+49******123";
        return json(
          { identifier: "SESSION-1", sessionTanActive: true, activated2FA: true },
          201,
          { "x-once-authentication-info": JSON.stringify(info) },
        );
      }
      if (method === "GET" && challenge && path === `/api/session/v1/authentications/${challenge.auth}`) {
        state.pushPolls += 1;
        challenge.polls += 1;
        if (opts.declinePush) return json({ authenticationId: challenge.auth, status: "FAILED" });
        if (opts.approveAfter !== null && challenge.polls >= opts.approveAfter) challenge.approved = true;
        return json({ authenticationId: challenge.auth, status: challenge.approved ? "AUTHENTICATED" : "PENDING" });
      }
      if (method === "PATCH" && path === `${session}/SESSION-1`) {
        state.patches += 1;
        const info = JSON.parse(headers.get("x-once-authentication-info") ?? "{}");
        const tan = headers.get("x-once-authentication");
        state.tans.push(tan);
        if (Object.keys(info).join() !== "id") return json({ code: "once.auth.invalid" }, 422);
        if (!challenge || info.id !== challenge.id) return json({ code: "once.auth.unknown" }, 422);
        const ok = opts.tanType === "P_TAN_PUSH" ? challenge.approved && tan === null : tan === opts.tan;
        challenge = null;
        if (!ok) return json({ code: "TAN_UNGUELTIG", messages: [{ severity: "ERROR", key: "TAN_UNGUELTIG", message: "TAN ungültig" }] }, 422);
        p.activated = true;
        return json({ identifier: "SESSION-1", sessionTanActive: true, activated2FA: true });
      }
      return empty(404);
    }
    if (!bearer || !banking.has(bearer)) return empty(401);
    if (method === "GET" && path === "/api/banking/clients/user/v2/accounts/balances") {
      return json({
        paging: { index: 0, matches: opts.accounts.length },
        values: opts.accounts.map((a) => ({
          accountId: a.accountId,
          account: {
            accountId: a.accountId,
            accountDisplayId: a.iban.slice(-10),
            currency: "EUR",
            iban: a.iban,
            bic: "COBADEHD001",
            accountType: { key: a.type, text: a.text },
          },
          balance: { value: a.balance ?? "100.00", unit: "EUR" },
          balanceEUR: { value: a.balance ?? "100.00", unit: "EUR" },
          availableCashAmount: { value: a.available ?? a.balance ?? "100.00", unit: "EUR" },
          availableCashAmountEUR: { value: a.available ?? a.balance ?? "100.00", unit: "EUR" },
        })),
      });
    }
    if (method === "GET" && path === "/api/reports/participants/user/v1/allbalances") {
      if (url.searchParams.get("productType") !== "CARD") state.problems.push("allbalances: not CARD");
      // As comdirect: no card number in the listing.
      return json({
        values: opts.cards.map((c) => ({
          productId: c.cardId,
          productType: "CARD",
          targetClientId: "CLIENT-1",
          clientConnectionType: "OWNER",
          balance: {
            cardId: c.cardId,
            card: { cardId: c.cardId, cardType: { key: "VISA_CREDIT" }, status: "ACTIVE", holderName: c.holder, cardLimit: { value: "1000", unit: "EUR" } },
            balance: { value: c.balance ?? "-12.34", unit: "EUR" },
            availableCashAmount: { value: (1000 + Number(c.balance ?? "-12.34")).toFixed(2), unit: "EUR" },
          },
        })),
      });
    }
    const card = /^\/api\/banking\/v1\/cards\/([^/]+)(\/transactions)?$/.exec(path);
    if (method === "GET" && card) {
      const c = opts.cards.find((c) => c.cardId === decodeURIComponent(card[1]));
      if (!c) return empty(404);
      if (!card[2]) {
        return json({
          cardId: c.cardId,
          cardType: { key: "VISA_CREDIT" },
          participantId: "P-1",
          cardValidity: "2029-12-31",
          status: "ACTIVE",
          cardDisplayId: `4871 78XX XXXX ${c.suffix}`,
          primaryAccountNumberSuffix: c.suffix,
          holderName: c.holder,
          cardLimit: { value: "1000", unit: "EUR" },
        });
      }
      const q = url.searchParams;
      if (q.get("transactionState") !== "BOOKED") state.problems.push("card transactions: not BOOKED");
      // comdirect refuses paging on cards.
      if (q.has("paging-first")) return json({ code: "request.query.invalid" }, 422);
      const count = Number(q.get("paging-count") ?? 20);
      if (count > 500) return json({ code: "request.query.invalid" }, 422);
      const min = q.get("min-bookingDate");
      state.minBookingDates.push(min ?? "");
      const all = (opts.cardTransactions[c.cardId] ?? []).filter((t) => {
        const day = (t as { bookingDate?: unknown }).bookingDate;
        return !min || typeof day !== "string" || day >= min;
      });
      return json({ paging: { index: 0, matches: all.length }, values: all.slice(0, count) });
    }
    const m = /^\/api\/banking\/v1\/accounts\/([^/]+)\/transactions$/.exec(path);
    if (method === "GET" && m) {
      const q = url.searchParams;
      if (q.get("transactionState") !== "BOOKED") state.problems.push("transactions: not BOOKED");
      const count = Number(q.get("paging-count") ?? 20);
      if (count > 500) return json({ code: "request.query.invalid" }, 422);
      const first = Number(q.get("paging-first") ?? 0);
      const min = q.get("min-bookingDate");
      state.minBookingDates.push(min ?? "");
      const all = (opts.transactions[decodeURIComponent(m[1])] ?? []).filter((t) => {
        const day = (t as { bookingDate?: unknown }).bookingDate;
        return !min || typeof day !== "string" || day >= min;
      });
      return json({ paging: { index: first, matches: all.length }, aggregated: {}, values: all.slice(first, first + count) });
    }
    return empty(404);
  }

  const fakeFetch = (async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.origin !== "https://api.comdirect.de") throw new TypeError(`fake comdirect: unexpected ${url.href}`);
    init?.signal?.throwIfAborted();
    const method = init?.method ?? "GET";
    state.calls.push(`${method} ${url.pathname}`);
    const headers = new Headers(init?.headers);
    const body = typeof init?.body === "string" ? init.body : "";
    return handle(method, url, headers, body);
  }) as typeof fetch;

  return {
    fetch: fakeFetch,
    state,
    opts,
    /** Approves the open push challenge. */
    approve() {
      if (challenge) challenge.approved = true;
    },
    /** comdirect forgets the refresh tokens (the session ran out). */
    expireSessions() {
      refresh.clear();
      banking.clear();
    },
  };
}

export type FakeComdirect = ReturnType<typeof fakeComdirect>;
