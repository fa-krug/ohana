// What a bank interface (a provider, e.g. comdirect) does for a sync, and what the sync gives
// it: the provider logs in (asking the user for a TAN through the hooks), finds the linked
// account and returns its booked transactions; the runner (runner.ts) keeps the sync's row up to
// date and imports what came back.

/** What a running sync does (the app's progress text). */
export type SyncStep = "login" | "tan" | "fetch" | "import";

/** The TAN the bank asks for: push (approve in the bank's app, nothing to type), photo (a
 *  photoTAN graphic, base64 PNG, to scan; then type the TAN) or sms (type the TAN; hint: the
 *  masked phone number). */
export interface TanChallenge {
  type: "push" | "photo" | "sms";
  image: string | null;
  hint: string | null;
}

/** A booked transaction as the bank lists it. */
export interface BankRow {
  day: string; // YYYY-MM-DD, the booking day
  amountCents: number; // negative: money going out
  payee: string;
  description: string;
  /** The bank's own id of the booking; null when it has none (then the row's content counts). */
  reference: string | null;
}

export interface BankStatement {
  /** The bank's id of the account the rows are from (part of their import hashes). */
  accountRef: string;
  rows: BankRow[];
}

/** A failure the user can act on; its message (English) becomes the sync's error. */
export class BankError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BankError";
  }
}

/** How a provider talks back to the sync. */
export interface SyncHooks {
  step(step: SyncStep): void;
  /** The bank refused the login (PIN or API credentials): no sync starts until the link is
   *  saved again, so a wrong PIN isn't tried until the bank locks the access. */
  loginRefused(): void;
  /** Called right BEFORE the bank is asked for a TAN challenge: counts it for the lockout guard
   *  (the bank locks the online banking after a few challenges without a confirmed TAN). */
  challenging(): void;
  /** The bank asks for a TAN: the app shows it (status "tan"). */
  challenge(tan: TanChallenge): void;
  /** Waits for the TAN the user types (POST …/bank/sync/tan); BankError after `ms`. */
  waitForTan(ms: number): Promise<string>;
  /** The TAN (or the approval) goes to the bank now. */
  confirming(): void;
  /** The bank accepted it. */
  confirmed(): void;
  /** Keeps the provider's session for the next sync (sealed), or forgets it (null). */
  saveSession(session: unknown): void;
}

export interface SyncTiming {
  /** Every request's timeout. */
  requestTimeoutMs: number;
  /** How long a TAN (typed or approved) is waited for. */
  tanTimeoutMs: number;
  /** How often an approval in the bank's app is checked. */
  pushPollMs: number;
}

export interface SyncRequest {
  /** The link's credentials, opened (the provider's own fields). */
  credentials: Record<string, string>;
  /** Which account at the bank (normalized IBAN); null: the only one there. */
  iban: string | null;
  /** What saveSession kept last time, or null. */
  session: unknown;
  /** The first booking day wanted. */
  from: string;
  signal: AbortSignal;
  fetch: typeof fetch;
  now: () => Date;
  timing: SyncTiming;
  hooks: SyncHooks;
}

export interface BankProvider {
  /** Stored in fin_bank_links.provider and the account DTO's bank.provider. */
  id: string;
  /** The credential fields PUT …/bank takes, all required for a new link. */
  credentialFields: readonly string[];
  /** Logs in and returns the booked transactions of the linked account from `from` on. */
  fetchStatement(req: SyncRequest): Promise<BankStatement>;
}
