// The sign-in pages' script (bundled by esbuild into public/assets/auth.js, see
// scripts/build-client.ts): it sends the forms of http/pages to /api/auth/... and runs the
// WebAuthn ceremonies. Pages work by `data-form` names; texts come rendered from the server.

import { startAuthentication, startRegistration } from "@simplewebauthn/browser";
import { homeFor } from "../lib/auth/redirect";

interface UserDto {
  onboardingStep: string;
}

async function post<T>(url: string, body?: unknown): Promise<T> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = (await res.json().catch(() => ({}))) as { message?: string; error?: string };
  if (!res.ok) throw new Error(data.message ?? data.error ?? "Request failed");
  return data as T;
}

function deviceName(): string {
  const ua = navigator.userAgent;
  const os = /iPhone|iPad/.test(ua) ? "iPhone/iPad" : /Android/.test(ua) ? "Android" : /Mac/.test(ua) ? "Mac" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "";
  const browser = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "";
  return [browser, os].filter(Boolean).join(" on ") || "Passkey";
}

async function passkeyLogin(email?: string): Promise<UserDto> {
  const optionsJSON = await post("/api/auth/webauthn/login/begin", email ? { email } : {});
  const credential = await startAuthentication({ optionsJSON: optionsJSON as never });
  return post<UserDto>("/api/auth/webauthn/login/complete", { credential: JSON.stringify(credential) });
}

async function passkeyRegister(args: { email: string; name: string; inviteCode?: string }): Promise<UserDto> {
  const optionsJSON = await post("/api/auth/webauthn/register/begin", args);
  const credential = await startRegistration({ optionsJSON: optionsJSON as never });
  return post<UserDto>("/api/auth/webauthn/register/complete", { credential: JSON.stringify(credential), deviceName: deviceName() });
}

async function addPasskey(): Promise<void> {
  const optionsJSON = await post("/api/auth/webauthn/add/begin");
  const credential = await startRegistration({ optionsJSON: optionsJSON as never });
  await post("/api/auth/webauthn/add/complete", { credential: JSON.stringify(credential), deviceName: deviceName() });
}

async function reauthAndChangeEmail(newEmail: string): Promise<void> {
  const optionsJSON = await post("/api/auth/webauthn/reauth/begin");
  const credential = await startAuthentication({ optionsJSON: optionsJSON as never });
  await post("/api/auth/webauthn/reauth/complete", { credential: JSON.stringify(credential), newEmail });
}

// ---- helpers ----

function field(form: HTMLFormElement, name: string): string {
  const el = form.elements.namedItem(name);
  return el instanceof HTMLInputElement || el instanceof HTMLSelectElement ? el.value : "";
}

function q<T extends Element = HTMLElement>(root: ParentNode, selector: string): T | null {
  return root.querySelector<T & Element>(selector) as T | null;
}

/**
 * Runs `fn` with the form's buttons disabled and its error cleared; shows the error it throws.
 * A cancelled passkey prompt (NotAllowedError) is no error.
 */
async function busy(form: HTMLFormElement, fn: () => Promise<void>, fallback?: string): Promise<void> {
  const error = q(form, "[data-error]");
  const buttons = Array.from(form.querySelectorAll("button"));
  if (error) error.hidden = true;
  buttons.forEach((b) => (b.disabled = true));
  try {
    await fn();
  } catch (err) {
    const e = err as Error;
    if (e.name !== "NotAllowedError" && error) {
      error.textContent = fallback ?? e.message;
      error.hidden = false;
    }
  } finally {
    buttons.forEach((b) => (b.disabled = false));
  }
}

function go(url: string): void {
  window.location.href = url;
}

function next(form: HTMLElement): string | null {
  return form.dataset.next || null;
}

// ---- the forms ----

const forms: Record<string, (form: HTMLFormElement) => void> = {
  language(form) {
    form.addEventListener("change", async () => {
      try {
        await post("/api/auth/language", { lang: field(form, "lang") });
      } finally {
        window.location.reload();
      }
    });
  },

  login(form) {
    let usePassword = false;
    const submit = q<HTMLButtonElement>(form, "button[type=submit]")!;
    const toggle = q<HTMLButtonElement>(form, "[data-toggle-password]")!;
    const show = () => {
      form.querySelectorAll<HTMLElement>("[data-password]").forEach((el) => (el.hidden = !usePassword));
      const label = q(submit, "[data-label]");
      if (label) label.textContent = (usePassword ? submit.dataset.passwordLabel : submit.dataset.passkeyLabel) ?? "";
      q(submit, "svg")?.toggleAttribute("hidden", usePassword);
      toggle.textContent = (usePassword ? toggle.dataset.passwordLabel : toggle.dataset.passkeyLabel) ?? "";
      const password = q<HTMLInputElement>(form, "input[name=password]");
      if (password) password.required = usePassword;
      const email = q<HTMLInputElement>(form, "input[name=email]");
      if (email) email.required = usePassword;
    };
    toggle.addEventListener("click", () => {
      usePassword = !usePassword;
      q(form, "[data-error]")?.setAttribute("hidden", "");
      show();
    });
    form.addEventListener("submit", (ev) => {
      ev.preventDefault();
      void busy(form, async () => {
        const email = field(form, "email").trim();
        const user = usePassword ? await post<UserDto>("/api/auth/login", { email, password: field(form, "password") }) : await passkeyLogin(email || undefined);
        go(homeFor(user, next(form)));
      });
    });
  },

  setup(form) {
    form.addEventListener("submit", (ev) => {
      ev.preventDefault();
      void busy(form, async () => {
        const user = await post<UserDto>("/api/auth/setup", { email: field(form, "email"), name: field(form, "name"), password: field(form, "password") });
        go(homeFor(user, next(form)));
      });
    });
    q(form, "[data-passkey]")?.addEventListener("click", () => {
      if (!form.reportValidity()) return;
      void busy(form, async () => {
        const user = await passkeyRegister({ email: field(form, "email"), name: field(form, "name") });
        go(homeFor(user, next(form)));
      });
    });
  },

  "setup-link"(form) {
    form.addEventListener("submit", (ev) => {
      ev.preventDefault();
      void busy(
        form,
        async () => {
          const user = await post<UserDto>("/api/auth/setup-link", { token: form.dataset.token });
          go(user.onboardingStep === "COMPLETED" ? "/account" : "/onboarding");
        },
        form.dataset.invalid,
      );
    });
  },

  "invite-register"(form) {
    const inviteCode = form.dataset.code ?? "";
    form.addEventListener("submit", (ev) => {
      ev.preventDefault();
      void busy(form, async () => {
        const user = await post<UserDto>("/api/auth/register", { email: field(form, "email"), name: field(form, "name"), password: field(form, "password"), inviteCode });
        go(homeFor(user));
      });
    });
    q(form, "[data-passkey]")?.addEventListener("click", () => {
      const email = q<HTMLInputElement>(form, "input[name=email]");
      if (email && !email.reportValidity()) return;
      void busy(form, async () => {
        const user = await passkeyRegister({ email: field(form, "email"), name: field(form, "name"), inviteCode });
        go(homeFor(user));
      });
    });
  },

  "invite-accept"(form) {
    form.addEventListener("submit", (ev) => {
      ev.preventDefault();
      void busy(form, async () => {
        const { familyId } = await post<{ familyId: string }>("/api/auth/invites/accept", { code: form.dataset.code });
        go(`/f/${encodeURIComponent(familyId)}`);
      });
    });
  },

  "onboarding-credentials"(form) {
    q(form, "[data-passkey]")?.addEventListener("click", () => {
      void busy(form, async () => {
        await addPasskey();
        go(next(form) ?? "/");
      });
    });
    q(form, "[data-show-password]")?.addEventListener("click", (ev) => {
      (ev.currentTarget as HTMLElement).hidden = true;
      const box = q(form, "[data-password]");
      if (box) box.hidden = false;
      q<HTMLInputElement>(form, "input[name=password]")?.focus();
    });
    form.addEventListener("submit", (ev) => {
      ev.preventDefault();
      void busy(form, async () => {
        await post("/api/auth/password", { newPassword: field(form, "password") });
        window.location.reload();
      });
    });
  },

  "onboarding-passkey"(form) {
    q(form, "[data-passkey]")?.addEventListener("click", () => {
      void busy(form, async () => {
        await addPasskey();
        go(next(form) ?? "/");
      });
    });
    q(form, "[data-skip]")?.addEventListener("click", () => {
      void busy(form, async () => {
        await post("/api/auth/skip-passkey");
        go(next(form) ?? "/");
      });
    });
  },

  pair(form) {
    const state = form.dataset.state ?? "";
    form.addEventListener("submit", (ev) => {
      ev.preventDefault();
      void busy(form, async () => {
        const { callbackUrl } = await post<{ callbackUrl: string }>("/api/auth/pair", { state, deviceName: form.dataset.deviceName ?? "" });
        go(callbackUrl);
      });
    });
    q(form, "[data-cancel]")?.addEventListener("click", () => {
      go(`ohana://auth-callback?${new URLSearchParams({ error: "cancelled", state })}`);
    });
  },

  logout(form) {
    form.addEventListener("submit", (ev) => {
      ev.preventDefault();
      void busy(form, async () => {
        await post("/api/auth/logout");
        go("/login");
      });
    });
  },

  "add-passkey"(form) {
    form.addEventListener("submit", (ev) => {
      ev.preventDefault();
      void busy(form, async () => {
        await addPasskey();
        accountChanged(form, "passkey");
      });
    });
  },

  email(form) {
    form.addEventListener("submit", (ev) => {
      ev.preventDefault();
      void busy(form, async () => {
        const newEmail = field(form, "newEmail").trim();
        if (form.dataset.hasPassword) await post("/api/auth/email", { newEmail, currentPassword: field(form, "currentPassword") });
        else await reauthAndChangeEmail(newEmail);
        accountChanged(form, "email");
      });
    });
  },

  password(form) {
    form.addEventListener("submit", (ev) => {
      ev.preventDefault();
      void busy(form, async () => {
        const currentPassword = field(form, "currentPassword");
        await post("/api/auth/password", { newPassword: field(form, "newPassword"), ...(currentPassword ? { currentPassword } : {}) });
        accountChanged(form, "password");
      });
    });
  },
};

/**
 * After a change on the account page: back to the app when it opened the page
 * (ohana://account-callback?state=…&changed=…), else the page reloads with a notice.
 */
function accountChanged(form: HTMLFormElement, changed: string): void {
  const state = form.closest<HTMLElement>("[data-account]")?.dataset.state;
  if (state) {
    go(`ohana://account-callback?${new URLSearchParams({ state, changed })}`);
    return;
  }
  try {
    sessionStorage.setItem("ohana.notice", form.dataset.done ?? "");
  } catch {
    // no storage: no notice
  }
  window.location.reload();
}

function showNotice(): void {
  const el = document.querySelector<HTMLElement>("[data-notice]");
  if (!el) return;
  let text: string | null = null;
  try {
    text = sessionStorage.getItem("ohana.notice");
    sessionStorage.removeItem("ohana.notice");
  } catch {
    return;
  }
  if (text) {
    el.textContent = text;
    el.hidden = false;
  }
}

function init(): void {
  document.querySelectorAll<HTMLFormElement>("form[data-form]").forEach((form) => forms[form.dataset.form ?? ""]?.(form));
  showNotice();
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
else init();
