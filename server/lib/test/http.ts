// Requests in tests: a JSON request signed in with an API token.

/** `method` on `url` with the Bearer `token` and `body` as JSON (none: no body). */
export function jsonRequest(url: string, method: string, token: string, body?: unknown): Request {
  const json = body !== undefined;
  return new Request(url, {
    method,
    headers: { authorization: `Bearer ${token}`, ...(json ? { "content-type": "application/json" } : {}) },
    body: json ? JSON.stringify(body) : undefined,
  });
}
