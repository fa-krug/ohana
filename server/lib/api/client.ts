// The browser side of the family API: JSON requests signed in by the session cookie (the
// pages' clients in components/*/api.ts use it).

export class ApiError extends Error {
  constructor(
    message: string,
    /** 0: no answer (offline). */
    public status: number,
  ) {
    super(message);
  }
}

export const enc = encodeURIComponent;

/** The API base of a family: /api/v1/families/{id}. */
export const fam = (id: string) => `/api/v1/families/${enc(id)}`;

export async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  let res: Response;
  try {
    res = await fetch(path, {
      method,
      credentials: "same-origin",
      cache: "no-store",
      headers: body === undefined ? {} : { "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch (err) {
    throw new ApiError((err as Error).message || "Network error", 0);
  }
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new ApiError(data?.error ?? res.statusText, res.status);
  return data as T;
}
