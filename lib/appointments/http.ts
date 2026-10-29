// Every outbound request of a search (Doctolib, jameda, Photon) carries a timeout, so a
// stalled connection fails that request (and, isolated per provider, at most that provider)
// instead of hanging the worker. The source app had no timeout; Ohana's worker runs many
// searches in one process, so it needs one.

const DEFAULT_TIMEOUT_SECONDS = 30;

export function requestTimeoutMs(): number {
  const raw = Number(process.env.APPT_REQUEST_TIMEOUT_SECONDS);
  return (Number.isFinite(raw) && raw > 0 ? raw : DEFAULT_TIMEOUT_SECONDS) * 1000;
}

/** An AbortSignal that fires after the request timeout. */
export function timeoutSignal(ms: number = requestTimeoutMs()): AbortSignal {
  return AbortSignal.timeout(ms);
}
