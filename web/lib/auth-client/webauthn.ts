"use client";

async function getWebAuthn() {
  return import("@simplewebauthn/browser");
}

async function post<T>(url: string, body?: unknown): Promise<T> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error((data as { message?: string }).message ?? "Request failed");
  }
  return data as T;
}

function deviceName(): string {
  const ua = navigator.userAgent;
  const os = /iPhone|iPad/.test(ua) ? "iPhone/iPad" : /Android/.test(ua) ? "Android" : /Mac/.test(ua) ? "Mac" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "";
  const browser = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "";
  return [browser, os].filter(Boolean).join(" on ") || "Passkey";
}

/** Signs in with a passkey; without an email the browser offers the passkeys it has. */
export async function passkeyLogin<T = unknown>(email?: string): Promise<T> {
  const { startAuthentication } = await getWebAuthn();
  const optionsJSON = await post("/api/auth/webauthn/login/begin", email ? { email } : {});
  const credential = await startAuthentication({ optionsJSON: optionsJSON as never });
  return post<T>("/api/auth/webauthn/login/complete", { credential: JSON.stringify(credential) });
}

/** Creates an account with a passkey: with an invite code, or the first account. */
export async function passkeyRegister<T = unknown>(args: { email: string; name: string; inviteCode?: string }): Promise<T> {
  const { startRegistration } = await getWebAuthn();
  const optionsJSON = await post("/api/auth/webauthn/register/begin", args);
  const credential = await startRegistration({ optionsJSON: optionsJSON as never });
  return post<T>("/api/auth/webauthn/register/complete", {
    credential: JSON.stringify(credential),
    deviceName: deviceName(),
  });
}

export async function addPasskey<T = unknown>(): Promise<T> {
  const { startRegistration } = await getWebAuthn();
  const optionsJSON = await post("/api/auth/webauthn/add/begin");
  const credential = await startRegistration({ optionsJSON: optionsJSON as never });
  return post<T>("/api/auth/webauthn/add/complete", {
    credential: JSON.stringify(credential),
    deviceName: deviceName(),
  });
}

export async function reauthAndChangeEmail<T = unknown>(newEmail: string): Promise<T> {
  const { startAuthentication } = await getWebAuthn();
  const optionsJSON = await post("/api/auth/webauthn/reauth/begin");
  const credential = await startAuthentication({ optionsJSON: optionsJSON as never });
  return post<T>("/api/auth/webauthn/reauth/complete", {
    credential: JSON.stringify(credential),
    newEmail,
  });
}
