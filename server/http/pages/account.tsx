// The pages for a signed-in browser: the start page (Ohana itself runs in the app), the account
// page the app opens for what needs the server's own site (passkeys, an email change confirmed
// with a passkey, a new password after a setup link), and the page links into a family open.

import type { FC } from "hono/jsx";
import type { PasskeyDto } from "@/lib/auth/passkey-management";
import { Card, ErrorText, Field, PasskeyIcon, type T } from "./layout";

export const HomePage: FC<{ t: T; name: string; serverUrl: string }> = ({ t, name, serverUrl }) => (
  <Card title={t("pages.home.title")} description={t("pages.home.signedInAs", { name })}>
    <p>{t("pages.home.useApp")}</p>
    <p class="server-url">
      <code>{serverUrl}</code>
    </p>
    <div class="actions">
      <a class="button primary" href="ohana://">
        {t("pages.openApp")}
      </a>
      <a class="button" href="/account">
        {t("pages.account.title")}
      </a>
      <form data-form="logout">
        <button type="submit" class="link">
          {t("pages.signOut")}
        </button>
      </form>
    </div>
  </Card>
);

export const OpenInAppPage: FC<{ t: T; link: string }> = ({ t, link }) => (
  <Card title={t("pages.open.title")} description={t("pages.open.description")}>
    <div class="actions">
      <a class="button primary" href={link}>
        {t("pages.openApp")}
      </a>
    </div>
  </Card>
);

function formatDate(d: Date | null, locale: string): string {
  return d ? d.toLocaleDateString(locale === "de" ? "de-DE" : "en-US", { year: "numeric", month: "short", day: "numeric" }) : "";
}

export const AccountPage: FC<{
  t: T;
  locale: string;
  email: string;
  name: string;
  hasPassword: boolean;
  canReset: boolean;
  passkeys: PasskeyDto[];
  /** The app's state when it opened the page: changes go back to the app. */
  state: string | null;
}> = ({ t, locale, email, name, hasPassword, canReset, passkeys, state }) => (
  <Card wide title={t("pages.account.title")} description={t("pages.home.signedInAs", { name: name || email })}>
    <div data-account data-state={state ?? ""}>
      <section class="part">
        <h2>{t("pages.account.passkeys")}</h2>
        {passkeys.length === 0 ? (
          <p class="hint">{t("pages.account.noPasskeys")}</p>
        ) : (
          <ul class="list">
            {passkeys.map((p) => (
              <li>
                <span>{p.deviceName}</span>
                <span class="hint">{t("pages.account.addedOn", { date: formatDate(p.createdAt, locale) })}</span>
              </li>
            ))}
          </ul>
        )}
        <form data-form="add-passkey" data-done={t("pages.account.passkeyAdded")}>
          <ErrorText />
          <button type="submit" class="primary">
            <PasskeyIcon />
            {t("pages.account.addPasskey")}
          </button>
        </form>
      </section>

      <section class="part">
        <h2>{t("pages.account.email")}</h2>
        <p class="hint">{email}</p>
        <form data-form="email" data-has-password={hasPassword ? "1" : ""} data-done={t("pages.account.emailChanged")}>
          <Field label={t("pages.account.newEmail")} name="newEmail" type="email" autocomplete="email" required />
          {hasPassword && <Field label={t("pages.account.currentPassword")} name="currentPassword" type="password" autocomplete="current-password" />}
          <ErrorText />
          <button type="submit">
            {hasPassword ? (
              t("pages.account.changeEmail")
            ) : (
              <>
                <PasskeyIcon />
                {t("pages.account.changeEmailWithPasskey")}
              </>
            )}
          </button>
        </form>
      </section>

      <section class="part">
        <h2>{t("pages.account.password")}</h2>
        <p class="hint">{hasPassword ? t("pages.account.passwordSet") : t("pages.account.noPassword")}</p>
        <form data-form="password" data-done={t("pages.account.passwordSaved")}>
          {hasPassword && !canReset && <Field label={t("pages.account.currentPassword")} name="currentPassword" type="password" autocomplete="current-password" />}
          <Field label={t("pages.account.newPassword")} name="newPassword" type="password" autocomplete="new-password" />
          <ErrorText />
          <button type="submit">{hasPassword ? t("pages.account.changePassword") : t("pages.account.setPassword")}</button>
        </form>
      </section>

      <p class="notice" data-notice role="status" hidden></p>
      <div class="actions">
        {state ? (
          <a class="button primary" href={`ohana://account-callback?${new URLSearchParams({ state })}`}>
            {t("pages.account.backToApp")}
          </a>
        ) : (
          <a class="button" href="/">
            {t("pages.account.back")}
          </a>
        )}
        <form data-form="logout">
          <button type="submit" class="link">
            {t("pages.signOut")}
          </button>
        </form>
      </div>
    </div>
  </Card>
);
