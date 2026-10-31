// The frame of every page the server still renders (sign-in, setup, onboarding, pairing the
// app, the account page): server-rendered HTML, one stylesheet and one small script
// (client/auth.ts → public/assets/auth.js) for the forms and the WebAuthn ceremonies.

import type { Child, FC } from "hono/jsx";
import type { Locale } from "@/lib/i18n/config";

export type T = (key: string, vars?: Record<string, string | number>) => string;

export interface PageProps {
  t: T;
  locale: Locale;
}

export const Layout: FC<{ t: T; locale: Locale; title: string; page: string; children?: Child }> = ({ t, locale, title, page, children }) => (
  <html lang={locale}>
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
      <meta name="color-scheme" content="light dark" />
      <meta name="theme-color" content="#0d9488" />
      <meta name="robots" content="noindex" />
      <title>{title === t("meta.title") ? title : `${title} · ${t("meta.title")}`}</title>
      <meta name="description" content={t("meta.description")} />
      <link rel="icon" href="/icon.svg" type="image/svg+xml" />
      <link rel="apple-touch-icon" href="/apple-icon.png" />
      <link rel="stylesheet" href="/assets/auth.css" />
      <script src="/assets/auth.js" defer></script>
    </head>
    <body data-page={page}>
      <main>
        <p class="brand">{t("meta.title")}</p>
        {children}
        <form class="language" data-form="language">
          <label>
            <span class="sr-only">{t("pages.language")}</span>
            <select name="lang" aria-label={t("pages.language")}>
              <option value="en" selected={locale === "en"}>
                {t("languages.en")}
              </option>
              <option value="de" selected={locale === "de"}>
                {t("languages.de")}
              </option>
            </select>
          </label>
        </form>
      </main>
    </body>
  </html>
);

export const Card: FC<{ title: string; description?: Child; children?: Child; wide?: boolean }> = ({ title, description, children, wide }) => (
  <section class={wide ? "card wide" : "card"}>
    <h1>{title}</h1>
    {description !== undefined && <p class="description">{description}</p>}
    {children}
  </section>
);

/** A field with its label. */
export const Field: FC<{
  label: string;
  name: string;
  type?: string;
  autocomplete?: string;
  required?: boolean;
  value?: string;
  hidden?: boolean;
  wrapAttr?: string;
}> = ({ label, name, type = "text", autocomplete, required, value, hidden, wrapAttr }) => (
  <div class="field" hidden={hidden} {...(wrapAttr ? { [wrapAttr]: "" } : {})}>
    <label for={name}>{label}</label>
    <input id={name} name={name} type={type} autocomplete={autocomplete} required={required} value={value} />
  </div>
);

/** Where a form shows its error (the script fills it). */
export const ErrorText: FC = () => <p class="error" role="alert" data-error hidden></p>;

export const PasskeyIcon: FC = () => (
  <svg class="icon" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <path d="M2.586 17.414A2 2 0 0 0 2 18.828V21a1 1 0 0 0 1 1h3a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h1a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h.172a2 2 0 0 0 1.414-.586l.814-.814a6.5 6.5 0 1 0-4-4z" />
    <circle cx="16.5" cy="7.5" r=".5" fill="currentColor" />
  </svg>
);
