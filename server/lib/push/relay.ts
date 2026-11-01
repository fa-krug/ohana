// The client of the push relay (relay/, phase 9): POST {relay}/v1/send with up to 100 sealed
// messages; one result per message. A relay that can't be reached or answers with an error
// gives `error` for every message (never throws).

export type RelayStatus = "ok" | "gone" | "invalid" | "limited" | "error";

export interface RelayMessage {
  relayToken: string;
  /** The sealed payload, base64 (at most 4000 characters). */
  payload: string;
  collapseId?: string;
  /** Seconds APNs keeps trying while the device is offline (at most a day). */
  ttl?: number;
}

export interface RelayResult {
  status: RelayStatus;
  retryAfter?: number;
}

export interface RelayClient {
  send(relayUrl: string, messages: RelayMessage[]): Promise<RelayResult[]>;
}

const BATCH = 100;
const TIMEOUT_MS = 10_000;
const STATUSES: readonly RelayStatus[] = ["ok", "gone", "invalid", "limited", "error"];

async function sendBatch(relayUrl: string, messages: RelayMessage[]): Promise<RelayResult[]> {
  const failed = (reason: string): RelayResult[] => {
    console.warn(`[push] relay ${relayUrl}: ${reason}`);
    return messages.map(() => ({ status: "error" }));
  };
  let res: Response;
  try {
    res = await fetch(`${relayUrl}/v1/send`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ messages }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (e) {
    return failed(e instanceof Error ? e.message : String(e));
  }
  if (res.status === 429) {
    const retryAfter = Number(res.headers.get("retry-after")) || 60;
    return messages.map(() => ({ status: "limited", retryAfter }));
  }
  if (!res.ok) return failed(`HTTP ${res.status}`);
  const body = (await res.json().catch(() => null)) as { results?: unknown } | null;
  const results = Array.isArray(body?.results) ? body.results : null;
  if (!results || results.length !== messages.length) return failed("unexpected answer");
  return results.map((r) => {
    const status = (r as { status?: unknown })?.status;
    const retryAfter = (r as { retryAfter?: unknown })?.retryAfter;
    return {
      status: STATUSES.includes(status as RelayStatus) ? (status as RelayStatus) : "error",
      ...(typeof retryAfter === "number" ? { retryAfter } : {}),
    };
  });
}

export const fetchRelay: RelayClient = {
  async send(relayUrl, messages) {
    const out: RelayResult[] = [];
    for (let i = 0; i < messages.length; i += BATCH) out.push(...(await sendBatch(relayUrl, messages.slice(i, i + BATCH))));
    return out;
  },
};
